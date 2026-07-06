# Container → Host Xcode Bridge

Claude Code runs inside a dev container (isolated personal credentials), but Xcode only
exists on the Mac host. This bridge lets the container trigger a **fixed, allowlisted set
of Xcode commands** on the host through the shared repo bind mount. No network, no SSH,
no arbitrary shell.

```
container (Claude Code)                    Mac host
┌─────────────────────┐   shared repo    ┌──────────────────────┐
│ scripts/container/  │   bind mount     │ scripts/host/        │
│   bridge (bash CLI) │ ──.bridge/queue─▶│   bridge-worker.py   │
│   writes request,   │ ◀─.bridge/jobs── │   validates verb,    │
│   tails log, exits  │   (log, result)  │   runs xcodebuild    │
│   with exit code    │                  │   via argv arrays    │
└─────────────────────┘                  └──────────────────────┘
```

Both sides **poll** the filesystem (worker 0.5s, client 0.25s). This is deliberate:
inotify/FSEvents events do not propagate across Docker Desktop bind mounts, so
event-driven watching would silently fail in exactly this topology.

## Setup

### Host (Mac), one time

```sh
cd /path/to/reader
./scripts/host/bridge-worker.sh
```

Leave it running in a terminal. It needs Xcode (or at least the Command Line Tools for
`python3`). Optional: install it as a launchd LaunchAgent so it runs in the background —
see [launchd](#optional-launchd-agent) below. Manual start is the recommended default:
it keeps worker (re)starts a deliberate host action (see [Security](#security-model)).

### Container

Open the repo in the dev container (`.devcontainer/devcontainer.json` puts
`scripts/container` on the PATH and installs `jq`). Then:

```sh
bridge status          # is the worker alive?
bridge xcode-version   # end-to-end smoke test
```

## CLI

```
bridge xcode-version                      # xcodebuild -version
bridge list-simulators                    # xcrun simctl list devices available
bridge list-schemes                       # xcodebuild -list -json
bridge build --scheme Reader [--configuration Debug] [--destination 'platform=iOS Simulator,name=iPhone 16']
bridge test  --scheme Reader [--configuration ...] [--destination ...]
bridge clean --scheme Reader
bridge boot-simulator --device 'iPhone 16'
bridge status
```

Global options: `--wait-timeout <s>` (how long to wait for the worker to claim the
request; default 30) and `--timeout <s>` (job execution timeout; per-verb default).
Output streams live; the CLI exits with the remote command's exit code. Ctrl-C requests
cancellation on the host (the worker kills the whole process group).

Exit codes: remote exit code on success path; `2` request rejected by the worker;
`124` job timed out; `130` cancelled; `7` no worker claimed the request in time.

## Protocol

Runtime state lives in `.bridge/` at the repo root (gitignored, created on demand):

```
.bridge/
├── queue/<id>.json         # pending requests (written via tmp + atomic rename)
├── jobs/<id>/
│   ├── request.json        # moved here from queue/ by the worker — the atomic claim
│   ├── state               # claimed | running | done   (each write is tmp + rename)
│   ├── log                 # append-only combined stdout+stderr of the job
│   ├── cancel              # touched by the client to request cancellation
│   └── result.json         # written (tmp + rename) BEFORE state becomes "done"
└── worker/
    └── heartbeat.json      # rewritten every 5s while the worker runs
```

### Request — `queue/<id>.json`

```json
{
  "protocol_version": 1,
  "id": "20260706T101530Z-4821-19377",
  "verb": "build",
  "args": {
    "scheme": "Reader",
    "configuration": "Debug",
    "destination": "platform=iOS Simulator,name=iPhone 16"
  },
  "created_at": "2026-07-06T10:15:30Z",
  "timeout_seconds": 1800
}
```

- `id`: `<UTC timestamp>-<pid>-<random>`. The timestamp prefix gives lexicographic FIFO
  ordering; pid+random avoids collisions without coordination.
- `timeout_seconds` is optional; the worker clamps it to `[1, per-verb max]` and applies
  the per-verb default when absent.
- Requests larger than 64 KB, with unknown fields where args are expected, or with
  `protocol_version != 1` are rejected.

### Result — `jobs/<id>/result.json`

```json
{
  "protocol_version": 1,
  "id": "20260706T101530Z-4821-19377",
  "status": "done",
  "exit_code": 0,
  "started_at": "2026-07-06T10:15:31Z",
  "finished_at": "2026-07-06T10:17:02Z",
  "error": null
}
```

`status` values: `done` (process ran; see `exit_code`), `rejected` (failed validation,
exit_code 2, `error` says why), `timeout` (124), `cancelled` (130), `worker-error` (1).

### Lifecycle

1. Client writes `queue/<id>.json.tmp`, then renames to `queue/<id>.json` — the worker
   can never observe a partially written request.
2. Worker picks the lexicographically smallest queue entry and claims it atomically:
   `mkdir jobs/<id>` then `rename(queue/<id>.json → jobs/<id>/request.json)`. If two
   workers ever race, the rename succeeds for exactly one.
3. Worker validates the request. Invalid → `result.json` with `status: rejected`.
4. Valid → `state: claimed` → spawn the child (own process group) → `state: running`.
   Output appends to `log`.
5. On exit/timeout/cancel the worker writes `result.json` first, **then** `state: done` —
   a client that sees `done` can always read a complete result.
6. Client tails `log` by byte offset while polling `state`; on `done` it drains the log,
   reads `result.json`, and exits with `exit_code`.

### Liveness, timeouts, cleanup

- **Heartbeat**: `worker/heartbeat.json` (`pid`, `host`, `ts`, `mode`) is rewritten every
  5 s. Liveness is judged by the `ts` *content*, not file mtime — mtime is unreliable
  across the macOS↔container bind mount. Stale means older than 15 s.
- **Timeout**: the child runs in its own process group; on deadline the worker sends
  SIGTERM to the group, waits 5 s, then SIGKILL.
- **Cancel**: the client touches `jobs/<id>/cancel`; the worker checks for it every
  second and kills the process group.
- **Stale cleanup** (worker start + every 10 min): queue entries older than 10 min are
  rejected as stale; job dirs older than 24 h are deleted; jobs left non-`done` by a
  worker crash are finished as `worker-error` on the next start.

## Verb allowlist

The worker executes **only** these verbs, each built as an argv array
(`subprocess.Popen(argv, shell=False)`) — request content never reaches a shell:

| Verb | Runs | Args (✱ = required) | Default / max timeout |
|---|---|---|---|
| `xcode-version` | `xcodebuild -version` | — | 30 s / 300 s |
| `list-simulators` | `xcrun simctl list devices available` | — | 30 s / 300 s |
| `list-schemes` | `xcodebuild -list -json -workspace/-project <discovered>` | — | 60 s / 300 s |
| `build` | `xcodebuild build … -scheme S [-configuration C] [-destination D] -derivedDataPath <host-local>` | scheme✱, configuration, destination | 1800 s / 7200 s |
| `test` | same shape, `test` action | scheme✱, configuration, destination | 2700 s / 7200 s |
| `clean` | `xcodebuild clean … -scheme S` | scheme✱ | 120 s / 600 s |
| `boot-simulator` | `xcrun simctl boot <device>` then `open -a Simulator` | device✱ | 60 s / 300 s |

Argument validation (enforced by the worker; the client duplicates it for fast feedback):

- `scheme`, `configuration`: `^[A-Za-z0-9][A-Za-z0-9 ._-]{0,99}$`
- `destination`: split on `,` into `key=value` pairs; key ∈ {platform, name, OS, id, arch};
  values validated like schemes (plus `()`); reassembled by the worker from validated pairs.
- `device`: simulator UDID or a name matching the scheme regex.
- **No value may start with `-`** — this blocks option injection
  (e.g. scheme `-derivedDataPath /Users/...`).
- `boot-simulator` treats `simctl` exit 149 ("already booted") as success.

The worker **discovers** the `*.xcworkspace` (preferred) or `*.xcodeproj` at the repo
root itself and realpath-checks it is inside the repo — requests never carry paths.
Until an Xcode project exists in the repo, project verbs return
`rejected: no Xcode project found`; `xcode-version` and `list-simulators` still work.

## Security model

- **Threat model**: the container is semi-trusted — it holds separate credentials and may
  run arbitrary code, and everything in the shared repo tree (request files *and these
  scripts*) is container-writable. The host worker is the sole trust boundary: it
  validates everything it reads from the tree and executes only the fixed verb table.
- **No shell, no injected flags**: fixed verbs, per-argument regexes, leading-`-`
  rejection, argv arrays with `shell=False`.
- **Path confinement**: project paths are discovered by the worker, never supplied by
  requests. DerivedData lives host-local at `~/Library/Caches/reader-bridge/DerivedData` —
  fast (off the bind mount) and out of the container's reach.
- **Minimal child environment**: the job gets a fresh env (`PATH`, `HOME`, `TMPDIR`,
  optional `DEVELOPER_DIR`); the host shell's variables and secrets never cross the bridge.
- **Limits**: 64 KB request cap, clamped timeouts, one job at a time, stale-request
  rejection, single-instance lock.
- **Residual risk — read this**: because the repo tree is shared, the container *can edit
  `scripts/host/bridge-worker.py`*. A running worker is unaffected by edits, but **review
  host-script changes on the host (e.g. `git diff scripts/host/`) before starting or
  restarting the worker.** This is also why manual start is the default rather than a
  KeepAlive launchd agent.
- File permissions inside the bind mount are advisory (Docker Desktop remaps ownership);
  confinement comes from validation, not filesystem ACLs.

## Optional: launchd agent

```sh
./scripts/host/install-launch-agent.sh      # installs com.reader.bridge-worker for this checkout
./scripts/host/uninstall-launch-agent.sh
```

The agent runs the worker at login and restarts it if it dies (`KeepAlive`). Note the
residual-risk caveat above: with KeepAlive, a worker restart is no longer a deliberate
host action, so only use it on a checkout you review.

## Testing without a Mac

`scripts/test/run-bridge-tests.sh` runs the real worker and real client on Linux against
mock `xcodebuild`/`xcrun` shims (`scripts/test/mock-bin/`), injected via the
`BRIDGE_XCODEBUILD` / `BRIDGE_XCRUN` env overrides. It covers the happy path, exit-code
propagation, rejection of malicious requests, timeout, cancel, no-worker behavior, and
stale-request cleanup. Other env seams used by tests: `BRIDGE_DIR` (queue location),
`BRIDGE_REPO_ROOT` (project-discovery root), `BRIDGE_STATE_DIR` (lock/DerivedData/logs).

## Troubleshooting

- **`bridge: no worker running on the host`** — start `./scripts/host/bridge-worker.sh`
  on the Mac (not in the container). `bridge status` shows heartbeat age.
- **Heartbeat always stale** — container/host clock skew. Docker Desktop normally syncs
  clocks; restarting Docker Desktop fixes drift after sleep.
- **`rejected: no Xcode project found`** — the repo root has no `.xcworkspace`/`.xcodeproj`
  yet, or more than one. Create the Xcode project at the repo root on the host.
- **Worker exits immediately: "another worker holds the lock"** — a worker is already
  running (maybe via launchd). `launchctl list | grep reader` / `uninstall-launch-agent.sh`.
- **Builds can't see local changes** — make sure the host worker runs in the same checkout
  the container mounts; the bridge builds the shared working tree, not a separate clone.
