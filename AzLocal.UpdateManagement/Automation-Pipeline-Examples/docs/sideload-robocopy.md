# Sideload copy throttling (robocopy)

> Companion to [sideload.md](sideload.md). Covers the `SIDELOAD_ROBOCOPY_SWITCHES`
> repository variable that tunes the detached copy worker.

The Step.6 sideload pipeline copies the `CombinedSolutionBundle` (or staged OEM SBE
package) to each cluster's infrastructure `import` SMB share using **robocopy**, run
inside a detached Windows Scheduled Task (`Tools/Invoke-AzLocalSideloadCopyTask.ps1`).
On a constrained on-prem link a full bundle can be tens of GB, so the copy is the longest
single operation in the whole workflow.

The worker always supplies a safe baseline set of switches. Anything you put in the
`SIDELOAD_ROBOCOPY_SWITCHES` repository variable is **appended** to that baseline, so use
it to add **retry, wait, and throttling** controls appropriate to your network.

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
| `/MT[:n]` | Multi-threaded copy (`n` threads, default 8). | A bundle is one large file, so `/MT` gives little benefit here and can increase contention - usually leave it off. |

## Examples

Throttle a shared WAN link to leave headroom for production traffic, with generous
retries:

```
/IPG:50 /R:10 /W:60
```

Restartable copy over an unreliable link:

```
/Z /R:10 /W:60
```

Fast, reliable LAN (no throttle needed):

```
/R:5 /W:30 /J
```

## Notes

- Logging (`/LOG`, `/TEE`), source/destination paths, and the file selection are managed
  by the worker - **do not** set those in `SIDELOAD_ROBOCOPY_SWITCHES`; only add the
  tuning switches above.
- A long copy is **expected** and does not hold a pipeline run open - the copy runs in
  the detached Scheduled Task while short, frequent pipeline runs report `Copying`
  progress via the shared-state heartbeat (see [sideload.md section 2](sideload.md#2-re-entrant-state-machine--scheduled-task-survival-model)).
- If a copy stalls past `SIDELOAD_HEARTBEAT_STALE_MINUTES`, the state machine re-drives it
  on the next live host (bounded by `MaxRetries`). Tune the stale window up if a slow but
  healthy `/IPG`-throttled copy is being re-driven prematurely.
