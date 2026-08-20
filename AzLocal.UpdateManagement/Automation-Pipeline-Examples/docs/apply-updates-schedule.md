# Configure the Apply Updates repeating schedule

## TL;DR

For first-time setup, generate a starter schedule from the rings currently
tagged in Azure:

```powershell
New-AzLocalApplyUpdatesScheduleConfig `
  -OutputPath .\config\apply-updates-schedule.yml `
  -Force
```

`-Force` replaces the untouched starter copied by
`Copy-AzLocalPipelineExample`. Do not use it to overwrite an operator-maintained
schedule without reviewing and preserving the existing policy.

Then:

1. Choose the cycle length. Four weeks is a common starting point; use a
  longer cycle when production needs more soak time.
2. Leave the generated anchor unchanged. It makes the current UTC ISO week
  cycle week 1 and lets the schedule repeat indefinitely.
3. Add a row for each cycle week and set of UTC days. Put rings that share the
  same week and days in one semicolon-separated value:

  ```yaml
  - weeksInCycle: '2'
    daysOfWeek:   'Mon-Thu'
    rings:        'Canary;DevTest;Ring1'
  ```

4. Commit and push the file, then run **Config: 3 - Apply-Updates Schedule
  Coverage Audit**. Follow its step-summary instructions to add the
  ready-to-paste apply cron to `apply-updates.yml`. Optionally apply its
  recommended monitor cron when tighter in-wave polling is required.

Use separate rows with the same `weeksInCycle` only when rings need different
days or row-level policies.

In one sentence: **the schedule selects eligible rings and days, the cron
wakes the workflow, and each cluster's tags gate preparation or installation.**
Preparation may bypass `UpdateStartWindow` when its schema policy allows it;
installation requires the window, and both operations honor
`UpdateExclusionsWindow` and `UpdateExcluded`.

## Why this model

`apply-updates-schedule.yml` is the day-level source of truth for which
`UpdateRing` values are eligible to apply updates on a given UTC date. It uses
an ISO 8601 week anchor and a repeating cycle instead of fixed calendar dates.

This approach was chosen so operators can define a rollout pattern once and
let it repeat across months and year boundaries. The file does not need a new
set of dates every month or year. Change-freeze dates remain separate in each
cluster's `UpdateExclusionsWindow` tag.

## Understand the three controls

Three independent controls determine whether an update can prepare or install:

1. `apply-updates-schedule.yml` selects the eligible rings for the current UTC
   cycle week and day.
2. The cron in `apply-updates.yml` determines when the workflow wakes.
3. Each cluster's tags determine whether the selected operation may proceed.
  `UpdateStartWindow` gates installation but not preparation;
  `UpdateExclusionsWindow` and `UpdateExcluded` block both.

The schedule file is a selector, not a trigger. A matching schedule row does
not start a workflow, and a cron firing does not bypass a cluster's start
window or exclusion settings.

## Configure the cycle

The cycle is controlled by three top-level values:

```yaml
cycleWeeks:           4
cycleAnchorISOWeek:   31
cycleAnchorYear:      2026
```

- `cycleAnchorISOWeek` and `cycleAnchorYear` identify the ISO week treated as
  **cycle week 1**.
- `cycleWeeks` is the number of weeks in the repeating cycle, from 1 to 52.
- `weeksInCycle` on each schedule row selects relative weeks within that
  cycle. It is not an ISO week number.

For example, with an anchor of ISO week 31 in 2026 and `cycleWeeks: 4`, ISO
week 31 is cycle week 1, ISO week 32 is cycle week 2, and the schedule returns
to cycle week 1 after cycle week 4.

The anchor remains fixed after the file is committed. Do not advance it each
week. The resolver calculates the current relative cycle week from the fixed
anchor and continues correctly across ISO year boundaries.

### Start the cycle now

The recommended method is to generate the file. The generator writes the
current UTC ISO week and ISO year as the anchor automatically:

```powershell
New-AzLocalApplyUpdatesScheduleConfig `
    -OutputPath .\config\apply-updates-schedule.yml
```

Review the generated cycle length and rows before enabling the schedule. A
four-week cycle is a practical starting point for monthly update operations;
increase it when production requires a longer soak period. Four weeks means
28 days and does not reset at the start of a calendar month. When no update is
Ready on an eligible day, there is no update to start.

### Find an ISO week and year manually

Use the following PowerShell 5.1-compatible calculation when manually
authoring the file or intentionally anchoring it to another UTC date. Replace
the first line with the required date; `[datetime]::UtcNow.Date` starts cycle
week 1 in the current UTC week.

```powershell
$dateUtc = [datetime]::UtcNow.Date
$isoDay = (([int]$dateUtc.DayOfWeek + 6) % 7)
$thursday = $dateUtc.AddDays(3 - $isoDay)
$isoYear = $thursday.Year
$january4 = [datetime]::new($isoYear, 1, 4)
$week1Monday = $january4.AddDays(-(([int]$january4.DayOfWeek + 6) % 7))
$isoWeek = [int][math]::Floor(($thursday - $week1Monday).TotalDays / 7) + 1

[pscustomobject]@{
    DateUtc = $dateUtc.ToString('yyyy-MM-dd')
    ISOWeek = $isoWeek
    ISOYear = $isoYear
}
```

ISO weeks start on Monday. ISO week 1 is the week containing the year's first
Thursday, so early January can belong to the previous ISO year and late
December can belong to the next ISO year. Always use both the returned week
and year.

References:

- [ISO week date](https://en.wikipedia.org/wiki/ISO_week_date)
- [ISO 8601](https://en.wikipedia.org/wiki/ISO_8601)

## Define schedule rows

Every row is evaluated independently against both `weeksInCycle` and
`daysOfWeek`:

```yaml
- weeksInCycle: '1'
  daysOfWeek:   'Mon'
  rings:        'Canary'
```

Supported selectors include:

| Field | Examples | Meaning |
|---|---|---|
| `weeksInCycle` | `'*'`, `'1'`, `'1-4'`, `'1,3,5'`, `'1-3,5,7'` | Relative cycle weeks from 1 through `cycleWeeks`; `'*'` means every cycle week. |
| `daysOfWeek` | `'*'`, `'Mon'`, `'Mon-Fri'`, `'Mon,Wed,Fri'`, `'Fri-Mon'` | UTC days; numeric values `0-6` are also accepted, where Sunday is 0. |
| `rings` | `'Canary'`, `'Ring1;Ring2'`, `'***'` | Semicolon-separated `UpdateRing` values; `***` selects every tagged ring and should be used with care. |

The common setup is one row containing every ring that shares the same cycle
week and day. Separate `UpdateRing` tag values with semicolons:

```yaml
- weeksInCycle: '2'
  daysOfWeek:   'Mon-Thu'
  rings:        'Canary;DevTest;Ring1'
```

That row makes every cluster tagged `Canary`, `DevTest`, or `Ring1` eligible
during the selected days in cycle week 2. The values in `rings` are ring names,
not individual cluster names.

Multiple rows using the same `weeksInCycle` value are optional. Use separate
rows when the rings need different days or row-level policies. If multiple
rows match the same cycle week and day, their rings are unioned and
deduplicated case-insensitively.

## Choose allowed update versions

Schema v2 requires a top-level `allowedUpdateVersions` value. It controls
which Ready updates the schedule is permitted to install:

```yaml
# No version constraint: install the latest Ready update.
allowedUpdateVersions: 'Latest'
```

Or provide a semicolon-separated allow-list of exact update names:

```yaml
allowedUpdateVersions: 'Solution12.2604.1003.1006;SBE5.0.2603.1522'
```

- `Latest` must appear alone and means no version constraint.
- Explicit values match the update `name` or `properties.version` exactly,
  case-insensitively. If no Ready update matches, the cluster is skipped with
  `NotInAllowList`; the workflow does not fall back to the latest update.
- Include a Ready OEM SBE update when it is a prerequisite for the next
  Microsoft Solution update.
- The top-level value applies to every schedule row unless that row defines
  its own `allowedUpdateVersions` override.

Discover exact names before editing the file:

```powershell
Get-AzLocalAvailableUpdates -ClusterName <name> -PassThru |
    Select-Object ClusterName, UpdateName, UpdateState
```

See [Restrict which updates each ring installs](../README.md#84-restrict-which-updates-each-ring-installs-allowedupdateversions-schema-v2)
for precedence, cross-row union behavior, SBE handling, and additional
examples.

## Configure preparation before installation

Schema v3 requires two top-level preparation booleans:

```yaml
prepareOnlyFirst: false
allowPrepareOnlyOutsideOfUpdateStartWindow: true
```

Set it to `true` to use the Azure Local 2608 two-phase workflow:

1. When the selected update is `Ready`, the current firing calls the prepare
  action. Azure downloads, validates/extracts, and health-checks the update,
  then advances it to `ReadyToInstall` asynchronously.
2. A later firing sees `ReadyToInstall` and calls apply. Installation proceeds
  only when `UpdateStartWindow` is open and no exclusion is active.

When `allowPrepareOnlyOutsideOfUpdateStartWindow` is `true`, preparation may
run before or outside the installation window so content and health checks can
start early. Set it to `false` to require preparation to pass
`UpdateStartWindow`. `UpdateExclusionsWindow` remains a hard blackout in both
modes, and `UpdateExcluded=True` remains an independent operator hold.

Any schedule row may override the fleet default:

```yaml
prepareOnlyFirst: false
allowPrepareOnlyOutsideOfUpdateStartWindow: true

schedule:
  - weeksInCycle: '1'
    daysOfWeek:   'Mon-Thu'
    rings:        'Canary'
    prepareOnlyFirst: true
    allowPrepareOnlyOutsideOfUpdateStartWindow: false
```

An omitted row value inherits its top-level setting. If multiple rows match a
firing and their explicit values for either policy conflict, resolution fails
closed instead of choosing one silently.

When a row effectively resolves both policies to `true`, **Config: 3 -
Apply-Updates Schedule Coverage Audit** recommends one deduplicated Apply
Updates cron six hours before each applicable `UpdateStartWindow` opening.
This gives the asynchronous download, validation/extraction, and
update-specific health checks an early opportunity to start; it does not
guarantee completion before installation. No extra cron is recommended when
`allowPrepareOnlyOutsideOfUpdateStartWindow` resolves to `false`, because the
early firing would be blocked. If subtracting six hours crosses midnight, the
reported cron uses the previous UTC day; make the ring eligible in the
schedule on that preparation day or the resolver will intentionally no-op.

## Example 1: basic four-week staged rollout

A four-week cycle provides a repeating operating pattern for Azure Local's
monthly update releases. This example introduces one rollout stage each week,
then starts the cycle again after week 4. Including earlier rings in later
rows allows them to continue receiving updates during the rollout. Weeks 2
and 3 demonstrate the common semicolon-separated multi-ring pattern. The
top-level `allowedUpdateVersions` list applies to every schedule row because
none defines an override.

```yaml
schemaVersion: 3

cycleWeeks:           4
cycleAnchorISOWeek:   31
cycleAnchorYear:      2026

allowedUpdateVersions: 'Solution12.2603.1002.502;Solution12.2604.1003.1006;SBE5.0.2603.1522;Solution12.2607.1003.70'
prepareOnlyFirst: false
allowPrepareOnlyOutsideOfUpdateStartWindow: true

schedule:
  - weeksInCycle: '1'
    daysOfWeek:   'Mon-Thu'
    rings:        'Canary'
    notes:        'Week 1 - canary'

  - weeksInCycle: '2'
    daysOfWeek:   'Mon-Thu'
    rings:        'Canary;DevTest'
    notes:        'Week 2 - development and test'

  - weeksInCycle: '3'
    daysOfWeek:   'Tue-Thu'
    rings:        'Canary;DevTest;Ring1'
    notes:        'Week 3 - first production ring'

  - weeksInCycle: '4'
    daysOfWeek:   'Tue-Thu'
    rings:        'Prod'
    notes:        'Week 4 - full production'
```

## Example 2: target several days in the same cycle week

`weeksInCycle` does not have to be unique. Each row is evaluated independently
against both its cycle week and UTC day. This four-week schedule uses three
separate week 1 rows to move through Canary, DevTest, and Ring1 on different
days before Production becomes eligible in week 2.

```yaml
schemaVersion: 3

cycleWeeks:           4
cycleAnchorISOWeek:   31
cycleAnchorYear:      2026

allowedUpdateVersions: 'Latest'
prepareOnlyFirst: false
allowPrepareOnlyOutsideOfUpdateStartWindow: true

schedule:
  - weeksInCycle: '1'
    daysOfWeek:   'Mon'
    rings:        'Canary'
    notes:        'Week 1 Monday - canary'

  - weeksInCycle: '1'
    daysOfWeek:   'Wed'
    rings:        'DevTest'
    notes:        'Week 1 Wednesday - development and test'

  - weeksInCycle: '1'
    daysOfWeek:   'Thu'
    rings:        'Ring1'
    notes:        'Week 1 Thursday - first production ring'

  - weeksInCycle: '2'
    daysOfWeek:   'Tue-Thu'
    rings:        'Prod'
    notes:        'Week 2 - full production'

  - weeksInCycle: '3-4'
    daysOfWeek:   'Mon'
    rings:        'Canary'
    notes:        'Weeks 3 and 4 - canary readiness checks'
```

On cycle week 1 Monday only Canary is selected. On Wednesday only DevTest is
selected, and on Thursday only Ring1 is selected. Reusing
`weeksInCycle: '1'` does not combine those rings because their days differ.

## Example 3: overlapping eight-week schedule

Use a longer cycle when production needs more soak time or when an estate does
not deploy every monthly update to every ring. This example combines staged
rows with an every-week canary row and a row-level update allow-list. On Monday
in cycle week 1, both Canary rows match; the resolver returns Canary once. On
Tuesday in cycle week 5, only Prod matches.

```yaml
schemaVersion: 3

cycleWeeks:           8
cycleAnchorISOWeek:   31
cycleAnchorYear:      2026

allowedUpdateVersions: 'Latest'
prepareOnlyFirst: false
allowPrepareOnlyOutsideOfUpdateStartWindow: true

schedule:
  - weeksInCycle: '1'
    daysOfWeek:   'Mon-Fri'
    rings:        'Canary'
    notes:        'Phase 1 - canary soak'

  - weeksInCycle: '2'
    daysOfWeek:   'Mon-Fri'
    rings:        'Canary;DevTest'
    notes:        'Phase 2 - DevTest joins canary'

  - weeksInCycle: '3-4'
    daysOfWeek:   'Mon-Thu'
    rings:        'Ring1;Ring2'
    notes:        'Phase 3 - early production rings'

  - weeksInCycle: '5-8'
    daysOfWeek:   'Tue-Thu'
    rings:        'Prod'
    allowedUpdateVersions: 'Solution12.2604.1003.1006;Solution12.2610.1003.XX'
    notes:        'Phase 4 - production with an explicit allow-list'

  - weeksInCycle: '*'
    daysOfWeek:   'Mon'
    rings:        'Canary'
    notes:        'Permanent Monday canary sweep'
```

## Preview and validate the schedule

Preview the calculated cycle before enabling scheduled runs:

```powershell
Get-AzLocalApplyUpdatesScheduleCycleCalendar `
    -SchedulePath .\config\apply-updates-schedule.yml
```

The default preview covers one complete cycle. Use `-StartDateUtc` and
`-Days` to inspect a particular period or more than one cycle.

### Activate the schedule and create the apply cron

After reviewing the schedule:

1. Commit and push `config/apply-updates-schedule.yml` so the pipeline can read
  the updated policy.
2. Run **Config: 3 - Apply-Updates Schedule Coverage Audit**.
3. Review its step summary. Resolve any reported mismatch between the schedule
  and live `UpdateRing` or `UpdateStartWindow` tags.
4. Follow the step-summary instructions and copy the **recommended apply cron**
  into `apply-updates.yml`, inside the
  `BEGIN/END-AZLOCAL-CUSTOMIZE:schedule-triggers` marker block. Config: 3
  provides the correct GitHub Actions `schedule:` or Azure DevOps
  `schedules:` format for the pipeline being audited.
5. **Optional:** Config: 3 also provides a recommended in-flight monitor
  schedule. To poll more frequently during update windows, follow its step
  summary and copy the **recommended monitor cron** into
  `monitor-updates.yml`, inside that file's
  `BEGIN/END-AZLOCAL-CUSTOMIZE:schedule-triggers` marker block. Replace or
  adjust the existing six-hour schedule rather than adding a conflicting
  second cadence.
6. Commit and push the updated pipeline file or files.
7. Run Config: 3 again and confirm that it reports the expected schedule and
  cron coverage without gaps.

The cron only wakes the Apply Updates workflow. The schedule still selects
the eligible rings for that UTC day, and each cluster's `UpdateStartWindow`
still gates the actual update start time. A scheduled run with no matching row
logs the reason and exits successfully without selecting any rings.

The monitor cron is not required for Update: 4 to run. `monitor-updates.yml`
ships with an active six-hour `-SkipWhenIdle` heartbeat, and Apply Updates
triggers it when an update starts. Use the Config: 3 monitor recommendation
only when the estate needs tighter in-wave polling than the default coverage.

## Common mistakes

- Do not put ISO week numbers in `weeksInCycle`; use relative cycle week
  numbers from 1 through `cycleWeeks`.
- Do not update the anchor every week. Change it only when intentionally
  restarting or realigning the cycle.
- Do not assume the schedule starts the workflow. Add cron triggers to
  `apply-updates.yml` that wake during the required cluster start windows.
- Do not assume one row is allowed per cycle week. Repeated week selectors are
  valid and useful for assigning different days or combining rings.
- Do not use local time when choosing the anchor or day. Schedule resolution
  uses UTC.