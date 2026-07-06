#!/bin/sh
# Launcher for the bridge worker. Run this on the Mac host, in this checkout.
set -eu
script_dir="$(cd "$(dirname "$0")" && pwd)"
if [ -x /usr/bin/python3 ]; then
  exec /usr/bin/python3 "$script_dir/bridge-worker.py" "$@"
fi
exec python3 "$script_dir/bridge-worker.py" "$@"
