# Sideload copy throttling (robocopy)

> Companion to [sideload.md](sideload.md). Covers the named copy profiles in
> `config/sideload-settings.yml`.

The Update: 2 sideload pipeline copies the `CombinedSolutionBundle` (or staged OEM SBE
package) to each cluster's infrastructure `import` SMB share using **robocopy**, run
inside a detached Windows Scheduled Task (`Tools/Invoke-AzLocalSideloadCopyTask.ps1`).
On a constrained on-prem link a full bundle can be tens of GB, so the copy is the longest
single operation in the whole workflow.

The workflow builds switches from the selected typed profile. Only retry count, wait,
inter-packet gap, restartable mode, and unbuffered mode are accepted.

For the complete Windows command syntax and Microsoft-defined behavior of each switch,
see [Robocopy - Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy).
The sideload worker intentionally exposes only the allow-listed subset below; paths,
logging, file selection, and all other switches are managed by the module.

## Default

```
/R:5 /W:30
```

- `/R:5` - retry a failed file up to **5** times.
- `/W:30` - wait **30 seconds** between retries.

This keeps a transient blip (a brief share hiccup, a momentary auth glitch) from failing
the whole copy, without retrying forever.

## Recommended switches for constrained links

| Switch | Effect | When to use |
|---|---|---|
| `/IPG:n` | **Inter-Packet Gap** - insert `n` milliseconds between packets to cap effective bandwidth. | The single most useful throttle. On a shared WAN/MPLS link, `/IPG:30`-`/IPG:75` keeps the copy from saturating the pipe and starving production traffic. Higher `n` = slower copy, less contention. |
| `/R:n` | Retry count. | Raise on a flaky link (`/R:10`); the default 5 is fine for most. |
| `/W:n` | Wait seconds between retries. | Raise (`/W:60`) when retries are usually due to a share that recovers slowly. |
| `/Z` | Restartable mode - resume a partially-copied large file after an interruption. | Large bundles over an unreliable link. Slightly slower but survives mid-file drops. |
| `/J` | Unbuffered I/O. | Very large files on a fast, reliable LAN - improves throughput. **Do not** combine with `/Z`. |

## Profile examples

The values below are generic examples only. Measure the link and validate the selected
profile in a non-production environment before using it for update media.

### Shared constrained link

Leave headroom for production traffic and tolerate transient interruptions:

```yaml
retryCount: 10
waitSeconds: 60
interPacketGapMilliseconds: 50
restartable: true
unbuffered: false
```

Effective allow-listed switches: `/R:10 /W:60 /IPG:50 /Z`.

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

- Logging, source/destination paths, and file selection are managed by the worker and
  cannot be injected through a profile.
- A long copy is **expected** and does not hold a pipeline run open - the copy runs in
  the detached Scheduled Task while short, frequent pipeline runs report `Copying`
  progress via the shared-state heartbeat (see [sideload.md section 2](sideload.md#2-re-entrant-state-machine--scheduled-task-survival-model)).
- If heartbeat or byte progress exceeds the configured stale window, the state machine
  re-drives it on the next live host. Tune the windows up if a slow but
  healthy `/IPG`-throttled copy is being re-driven prematurely.
