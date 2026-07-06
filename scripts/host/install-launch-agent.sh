#!/bin/sh
# Install the bridge worker as a launchd LaunchAgent for THIS checkout (macOS only).
# Caveat: with KeepAlive, worker restarts are no longer a deliberate action — review
# scripts/host/ changes before relying on this. See docs/bridge.md "Security model".
set -eu
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
label="com.reader.bridge-worker"
plist="$HOME/Library/LaunchAgents/$label.plist"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Caches/reader-bridge"
sed -e "s|__REPO__|$repo_root|g" -e "s|__HOME__|$HOME|g" \
  "$script_dir/$label.plist" > "$plist"

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "Installed and started $label for $repo_root"
echo "Logs: ~/Library/Caches/reader-bridge/launchd.err.log"
