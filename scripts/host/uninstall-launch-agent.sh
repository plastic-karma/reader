#!/bin/sh
# Remove the bridge worker LaunchAgent (macOS only).
set -eu
label="com.reader.bridge-worker"
plist="$HOME/Library/LaunchAgents/$label.plist"

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$plist"
echo "Uninstalled $label"
