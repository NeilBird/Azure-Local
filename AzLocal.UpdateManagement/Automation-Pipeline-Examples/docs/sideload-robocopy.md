# Sideload copy throttling (robocopy)

> Companion to [sideload.md](sideload.md). Covers the named copy profiles in
> `config/sideload-settings.yml`.

The Update: 2 sideload pipeline copies the `CombinedSolutionBundle` (or staged OEM SBE
package) to each cluster's infrastructure `import` SMB share using **robocopy**, run
inside a detached Windows Scheduled Task (`Tools/Invoke-AzLocalSideloadCopyTask.ps1`).
On a constrained on-prem link a full bundle can be tens of GB, so the copy is the longest
single operation in the whole workflow.

The workflow builds switches from the selected typed profile. Retry count, wait,
inter-packet gap, restartable mode, unbuffered mode, requested I/O rate, and detailed
logging are accepted. There is no unrestricted raw-argument setting.

For the complete Windows command syntax and Microsoft-defined behavior of each switch,
see [Robocopy - Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy).
The sideload worker intentionally exposes only the allow-listed subset below; paths,
logging, file selection, and all other switches are managed by the module.

## Default

```
/R:5 /W:30 /Z
```

- `/R:5` - retry a failed file up to **5** times.
- `/W:30` - wait **30 seconds** between retries.
- `/Z` - restartable copying, enabled by the starter profile.

These are the pipeline defaults selected from the starter's `balanced` profile.
The worker's standalone fallback is `/R:5 /W:30`; the pipeline supplies the full
selected profile explicitly.

This keeps a transient blip (a brief share hiccup, a momentary auth glitch) from failing
the whole copy, without retrying forever.

## Recommended switches for constrained links

| Switch | Effect | When to use |
|---|---|---|
| `/IPG:n` | **Inter-Packet Gap** - insert `n` milliseconds between packets to slow copying. This is not a precise Mbps cap. | Measure a non-production copy and adjust the delay to leave headroom for production traffic. The resulting rate depends on the link, SMB behavior, and concurrent copies. |
| `/R:n` | Retry count. | Raise on a flaky link (`/R:10`); the default 5 is fine for most. |
| `/W:n` | Wait seconds between retries. | Raise (`/W:60`) when retries are usually due to a share that recovers slowly. |
| `/Z` | Restartable mode - resume a partially-copied large file after an interruption. | Large bundles over an unreliable link. Slightly slower but survives mid-file drops. |
| `/J` | Unbuffered I/O. | Very large files on a fast, reliable LAN - improves throughput. **Do not** combine with `/Z`. |
| `/IORATE:n` | Requested copy I/O rate in bytes per second. | Use `ioRateBytesPerSecond` on a runner whose robocopy supports it. The minimum enabled value is 524288; 0 disables this option. |
| `/V /TS /FP /BYTES` | Include skipped files, source timestamps, full paths, and byte sizes in the managed log. | Set `detailedLogging: true` when investigating a copy. The worker also retains the job header and summary in this mode. |

## Profile examples

The values below are generic examples only. Measure the link and validate the selected
profile in a non-production environment before using it for update media.

### Shared constrained link

Edit the generated `config/sideload-settings.yml`, not just the module's
`sideload-settings.example.yml`. Select a named profile under `copy.defaultProfile`;
both GitHub Actions and Azure DevOps build their robocopy switches from that profile.
For example, replace or extend the existing `copy` section with:

```yaml
copy:
  defaultProfile: slowWan
  profiles:
    slowWan:
      retryCount: 10
      waitSeconds: 60
      interPacketGapMilliseconds: 50
      restartable: true
      unbuffered: false
```

Effective allow-listed switches: `/R:10 /W:60 /IPG:50 /Z`.

Retry/wait values affect failed copies only; they do not slow healthy transfers.
Tune `interPacketGapMilliseconds` and `reconciliation.maxConcurrentCopies` together
to control aggregate load. A changed profile applies when a new copy task starts;
it does not change an already-running robocopy process. Arbitrary extra switches are
not accepted. For a strict bandwidth ceiling, use a separately validated network or
Windows QoS policy rather than treating `/IPG` as a bandwidth reservation.

### Unreliable link

Prefer restartability without an inter-packet delay:

```yaml
retryCount: 10
waitSeconds: 60
interPacketGapMilliseconds: 0
restartable: true
unbuffered: false
```

Effective allow-listed switches: `/R:10 /W:60 /Z`.

### Fast, reliable LAN

Use unbuffered I/O without restartable mode:

```yaml
retryCount: 5
waitSeconds: 30
interPacketGapMilliseconds: 0
restartable: false
unbuffered: true
```

Effective allow-listed switches: `/R:5 /W:30 /J`.

## Notes

### Rate-limited diagnostic profile

Prefer `ioRateBytesPerSecond` (`/IORATE`) when the runner supports it: a requested
bytes-per-second rate is easier to size and measure than a delay. Use
`interPacketGapMilliseconds` (`/IPG`) as the compatibility fallback, tuning its delay
against observed throughput. Both slow healthy copies, unlike `/R` and `/W`, which
only control retries. Neither is a guaranteed network bandwidth cap; use network
QoS when a hard shared-link limit is required. Set the unused throttle to 0.

```yaml
copy:
  defaultProfile: measuredWan
  profiles:
    measuredWan:
      retryCount: 5
      waitSeconds: 30
      interPacketGapMilliseconds: 0
      restartable: true
      unbuffered: false
      ioRateBytesPerSecond: 10485760
      detailedLogging: true
```

This requests 10 MiB/s of copy I/O **per robocopy process**, not a fleet-wide network
cap. Robocopy/Windows may adjust the requested value and network overhead differs
from file I/O. For two concurrent copies, plan for roughly twice the requested file
I/O rate plus overhead; measure actual traffic. The module permits 0 or integer rates
from 524288 through 1099511627776 bytes/s and rejects combining a nonzero rate with
nonzero inter-packet pacing as a configuration policy. Use one throttle method.

Task registration checks `robocopy /?` on the runner for `/IORATE` support and fails
with an actionable message if it is unavailable; it never silently drops the limit.
Omitting either new field preserves existing behavior (rate disabled, detailed logging
off). Adding fields does not require replacing the existing settings file or changing
its schema version. Existing active tasks keep the profile with which they started.

### Logging and downloadable diagnostics

- The pipeline always attempts to publish its diagnostics artifact, including on
  failure. Timing JSON is produced independently of verbose diagnostics; the transcript
  is included only when diagnostics are enabled and the step reaches transcript startup.
- **GitHub Actions:** select `diagnostics=true` for the manual run, or set repository
  variable `DEBUG_VERBOSE=true`. Download the `azlocal-sideload-updates-diagnostics_*`
  artifact from the run's Artifacts section; GitHub provides the artifact as a ZIP.
- **Azure DevOps:** select `diagnostics=true` for a manual run, or set the shared
  `DEBUG_VERBOSE` variable to `true`. Download `azlocal-sideload-updates-diagnostics-*`
  from the run's published artifacts. This is a pipeline artifact, not a ZIP file
  explicitly created by the script; use the service's artifact download facility.
- The detached worker writes `paths.stateRoot\logs\<cluster>.<timestamp>.robocopy.log`.
  Its path is recorded in `state\<cluster>.json` alongside the task owner, operation ID,
  worker/copy process IDs, heartbeat, progress, exit code, and failure message.
  With diagnostics enabled, both pipelines attempt to add a compressed snapshot,
  `sideload-copy-diagnostics.zip`, to the diagnostics artifact in their cleanup block,
  including after reconciliation failures when settings and a plan are available.
- The ZIP contains the current referenced copy log for each selected cluster and an
  allowlisted state-metadata manifest, not the entire shared state/log directory.
  Defaults are the last **5 MiB per log**, **50 MiB total log data**, and **100 distinct
  clusters** (sorted by name). The manifest records UTC collection times, byte offsets,
  captured lengths, truncation, missing/locked files, rejected paths, budget omissions,
  and omitted-cluster count. A byte-tail can start mid-line or mid-character.
  No-log and empty-plan cases still produce a manifest. Inspect it before assuming
  a bundle is complete; the shared originals remain authoritative.
- Collection reads with file sharing enabled and never stops a worker or changes its
  logs. A writer that denies shared reads is reported as unavailable. Log paths must
  point directly into the configured `logs` directory and end in `.robocopy.log`;
  file/directory reparse points are rejected. The configured shared root and its
  ancestors must be trusted storage. File/byte limits do not impose an SMB I/O timeout.
- `detailedLogging` controls the copy log, not the pipeline transcript. A pipeline
  transcript cannot capture a detached task's later output. The ZIP is also only a
  snapshot: download a later diagnostic run's artifact or collect the original from
  the shared root for final output. Old ZIPs are removed at the next state-machine
  step startup to avoid publishing stale snapshots on reused runners.
  GitHub also uses a run/attempt-specific ZIP directory, so a skipped step cannot
  cause the upload of a previous run's copy snapshot.
- Internal runner/agent service `_diag` logs, Windows Task Scheduler event logs, and
  remote-cluster logs are **not included** in the module artifact. Collect them on
  the recorded owning VM or cluster when needed using the platform's support procedure.
- Logs can contain cluster names, account names, UNC paths, and operational details.
  Restrict artifact/share access and retention; do not publish them in a public issue.

### Operational notes

- Logging, source/destination paths, and file selection are managed by the worker and
  cannot be injected through a profile.
- A long copy is **expected** and does not hold a pipeline run open - the copy runs in
  the detached Scheduled Task while short, frequent pipeline runs report `Copying`
  progress via the shared-state heartbeat (see [sideload.md section 2](sideload.md#2-re-entrant-state-machine--scheduled-task-survival-model)).
- If heartbeat or byte progress exceeds the configured stale window, the state machine
  re-drives it on the next live host. Tune the windows up if a slow but
  healthy `/IPG`-throttled copy is being re-driven prematurely.
