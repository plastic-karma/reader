# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A SwiftUI/SwiftData iOS/macOS app (`reader/`) developed from inside a Linux dev container, where Xcode doesn't exist. All Xcode operations go through a file-based **container→host bridge**: the `bridge` CLI in the container writes request files into `.bridge/queue/`, and `bridge-worker.py` running on the Mac host picks them up, validates them, and runs an allowlisted set of `xcodebuild`/`simctl` commands. Full protocol and security model: `docs/bridge.md`.

## Commands

```sh
bridge status                 # is the host worker alive?
bridge xcode-version          # end-to-end smoke test
bridge list-schemes
bridge build --scheme reader [--configuration Debug] [--destination 'platform=iOS Simulator,name=iPhone 16']
bridge test  --scheme reader [--configuration ...] [--destination ...]
bridge clean --scheme reader
bridge list-simulators
bridge boot-simulator --device 'iPhone 16'
```

The Xcode scheme is `reader` (lowercase; the README's `Reader` examples are illustrative). Global options: `--wait-timeout <s>` (wait for worker claim, default 30), `--timeout <s>` (job execution). The CLI streams the job log live and exits with the remote exit code (`2` rejected, `124` timeout, `130` cancelled, `7` no worker).

There is no way to run individual Swift tests through the bridge — `bridge test` runs the whole test action. If `bridge` reports no worker, the host-side worker isn't running; that must be started on the Mac (`./scripts/host/bridge-worker.sh`), not from the container.

### What the bridge can (and can't) do

The worker executes **only** this fixed verb table — each as an argv array, never a shell:

| Verb | Runs on the host | Required args | Default / max timeout |
|---|---|---|---|
| `xcode-version` | `xcodebuild -version` | — | 30 s / 300 s |
| `list-simulators` | `xcrun simctl list devices available` | — | 30 s / 300 s |
| `list-schemes` | `xcodebuild -list -json` | — | 60 s / 300 s |
| `build` | `xcodebuild build -scheme …` | scheme | 1800 s / 7200 s |
| `test` | `xcodebuild test -scheme …` | scheme | 2700 s / 7200 s |
| `clean` | `xcodebuild clean -scheme …` | scheme | 120 s / 600 s |
| `boot-simulator` | `xcrun simctl boot` + `open -a Simulator` | device | 60 s / 300 s |

Anything else (arbitrary shell, extra xcodebuild flags, custom paths) is impossible by design — don't try to work around it from the container; extend the verb table in `bridge-worker.py` instead (and mirror it in the `bridge` client and tests). DerivedData lives host-local at `~/Library/Caches/reader-bridge/DerivedData`, not in the repo. Ctrl-C on the client requests cancellation on the host (the worker kills the job's process group).

### Bridge integration tests (run on Linux, no Xcode needed)

```sh
./scripts/test/run-bridge-tests.sh
```

Runs the real worker + real client against mock `xcodebuild`/`xcrun` shims in `scripts/test/mock-bin/`, covering the happy path, exit-code propagation, malicious-request rejection, timeout, cancel, and stale cleanup. Run this after any change to `scripts/host/bridge-worker.py` or `scripts/container/bridge`.

## Architecture

- `reader/` — the Xcode project. Standard SwiftUI + SwiftData template layout: `readerApp.swift` (app entry, `ModelContainer` setup), `ContentView.swift`, `Item.swift` (SwiftData model), plus `readerTests/` and `readerUITests/`.
- `scripts/container/bridge` — bash client (on PATH inside the dev container). Writes a request JSON atomically (tmp + rename), tails the job log by byte offset while polling `state`, reads `result.json` when state is `done`.
- `scripts/host/bridge-worker.py` — the single trust boundary. Polls `.bridge/queue/` (0.5 s; polling is deliberate — inotify doesn't cross Docker Desktop bind mounts), claims jobs atomically via rename, validates verb + per-argument regexes, and executes argv arrays with `shell=False`. One job at a time; heartbeat in `.bridge/worker/heartbeat.json` every 5 s.
- `.bridge/` — runtime state (gitignored): `queue/`, `jobs/<id>/{request.json,state,log,result.json,cancel}`, `worker/heartbeat.json`.

### Constraints that matter when changing the bridge

- The worker never trusts request content: fixed verb table, argument regexes, leading-`-` rejection (blocks option injection), no paths in requests — the worker discovers the `.xcworkspace`/`.xcodeproj` itself (repo root or one level below, exactly one allowed).
- Write ordering is load-bearing: `result.json` is written *before* `state` becomes `done`; all state/request writes are tmp + atomic rename. Preserve this in any protocol change.
- Client-side validation in `bridge` duplicates the worker's for fast feedback — keep the two in sync.
- Env seams for testing: `BRIDGE_DIR`, `BRIDGE_REPO_ROOT`, `BRIDGE_STATE_DIR`, `BRIDGE_XCODEBUILD`, `BRIDGE_XCRUN`.
- Security note: the container can edit `scripts/host/*` since the repo tree is shared; the model relies on the host reviewing `git diff scripts/host/` before (re)starting the worker. Don't weaken worker-side validation on the assumption the client is trusted — it isn't.
