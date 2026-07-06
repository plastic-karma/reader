# reader

iOS/macOS app, developed with Claude Code running inside a dev container while Xcode
builds run on the Mac host through a limited file-based bridge.

The app is a focused macOS reader: RSS/Atom feeds, saved-page snapshots, and
**Gmail newsletters** — register sender + subject-regex rules and matching
messages appear as offline-rendered articles while being archived out of your
inbox (setup: [docs/gmail-setup.md](docs/gmail-setup.md)).

## Quickstart

1. **Host (Mac):** start the bridge worker in this checkout:
   ```sh
   ./scripts/host/bridge-worker.sh
   ```
2. **Container:** open the repo in the dev container (VS Code → "Reopen in Container"),
   then:
   ```sh
   bridge status          # worker alive?
   bridge xcode-version   # end-to-end smoke test
   bridge build --scheme Reader
   ```

The bridge only executes an allowlisted set of xcodebuild/simctl verbs with validated
arguments — the container never gets shell access to the host. Protocol, security model,
and troubleshooting: [docs/bridge.md](docs/bridge.md).
