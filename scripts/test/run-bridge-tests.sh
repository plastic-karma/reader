#!/usr/bin/env bash
# Integration tests for the container->host bridge. Runs the REAL worker and REAL
# client on Linux (or macOS) against mock xcodebuild/xcrun shims — no Xcode needed.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
client="$repo_root/scripts/container/bridge"
worker="$repo_root/scripts/host/bridge-worker.py"

work="$(mktemp -d)"
fake_root="$work/repo"
mock="$work/mock-bin"
export BRIDGE_DIR="$work/bridge"
state="$work/state"

mkdir -p "$fake_root/Reader.xcodeproj" "$BRIDGE_DIR/queue" "$BRIDGE_DIR/jobs"
cp -a "$script_dir/mock-bin" "$mock"
chmod +x "$mock/xcodebuild" "$mock/xcrun"

worker_pid=""
cleanup() {
  [ -n "$worker_pid" ] && kill "$worker_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok: $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL: $1" >&2; }
check() { # description, condition-result ($?-style)
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}

set_control() { printf '%s\n' "$@" > "$mock/mock-control"; }
clear_control() { rm -f "$mock/mock-control"; }
invocation_count() { wc -l < "$mock/invocations.log" 2>/dev/null || echo 0; }

drop_request() { # id json
  printf '%s' "$2" > "$BRIDGE_DIR/queue/$1.json.tmp"
  mv "$BRIDGE_DIR/queue/$1.json.tmp" "$BRIDGE_DIR/queue/$1.json"
}

wait_for() { # description, timeout_s, command...
  local desc="$1" deadline=$(( $(date +%s) + $2 )); shift 2
  while ! "$@" 2>/dev/null; do
    [ "$(date +%s)" -ge "$deadline" ] && { bad "timed out waiting: $desc"; return 1; }
    sleep 0.2
  done
}

result_status() { jq -r '.status' "$BRIDGE_DIR/jobs/$1/result.json" 2>/dev/null; }
has_result() { [ -f "$BRIDGE_DIR/jobs/$1/result.json" ]; }

start_worker() {
  BRIDGE_REPO_ROOT="$fake_root" BRIDGE_STATE_DIR="$state" \
  BRIDGE_XCODEBUILD="$mock/xcodebuild" BRIDGE_XCRUN="$mock/xcrun" \
    python3 "$worker" >"$work/worker-stderr.log" 2>&1 &
  worker_pid=$!
  wait_for "worker heartbeat" 10 test -f "$BRIDGE_DIR/worker/heartbeat.json"
}

echo "== 1. no worker: client gives up with exit 7 and a helpful message"
out="$("$client" xcode-version --wait-timeout 2 2>&1)"; rc=$?
check "exit code 7" "$([ "$rc" -eq 7 ]; echo $?)"
check "message mentions no worker" "$(grep -q 'no worker' <<<"$out"; echo $?)"

echo "== 2. stale queue entry is rejected on worker start"
stale_id="20200101T000000Z-1-1"
drop_request "$stale_id" '{"protocol_version":1,"id":"'"$stale_id"'","verb":"xcode-version","args":{},"created_at":"2020-01-01T00:00:00Z"}'

start_worker
wait_for "stale entry result" 10 has_result "$stale_id"
check "stale request rejected" "$([ "$(result_status "$stale_id")" = rejected ]; echo $?)"

echo "== 3. bridge status reports alive worker"
out="$("$client" status)"; rc=$?
check "status exit 0" "$([ "$rc" -eq 0 ]; echo $?)"
check "status says alive" "$(grep -q 'alive' <<<"$out"; echo $?)"

echo "== 4. xcode-version round trip"
out="$("$client" xcode-version)"; rc=$?
check "exit 0" "$([ "$rc" -eq 0 ]; echo $?)"
check "streams mock output" "$(grep -q 'Xcode 16.4' <<<"$out"; echo $?)"

echo "== 5. list-simulators round trip"
out="$("$client" list-simulators)"; rc=$?
check "exit 0" "$([ "$rc" -eq 0 ]; echo $?)"
check "lists devices" "$(grep -q 'iPhone 16' <<<"$out"; echo $?)"

echo "== 6. build: exit code propagates from the host command"
set_control "exit_c=65"
out="$("$client" build --scheme Reader --destination 'platform=iOS Simulator,name=iPhone 16')"; rc=$?
clear_control
check "client exits 65" "$([ "$rc" -eq 65 ]; echo $?)"
check "build output streamed" "$(grep -q 'MOCK-XCODEBUILD' <<<"$out"; echo $?)"

echo "== 7. malicious/invalid requests are rejected, nothing executes"
before="$(invocation_count)"
out="$("$client" build --scheme '; rm -rf /' 2>&1)"; rc=$?
check "client blocks shell-metachar scheme (exit 2)" "$([ "$rc" -eq 2 ]; echo $?)"
out="$("$client" build --scheme '-derivedDataPath /tmp/x' 2>&1)"; rc=$?
check "client blocks dash-prefixed scheme (exit 2)" "$([ "$rc" -eq 2 ]; echo $?)"
for bad_req in \
  'nuke {"whatever":1}' \
  'build {"scheme":"; rm -rf /"}' \
  'build {"scheme":"-derivedDataPath /tmp/x"}' \
  'build {"scheme":"Reader","extra_flag":"-quiet"}'; do
  verb="${bad_req%% *}"; args="${bad_req#* }"
  id="test-reject-$RANDOM$RANDOM"
  drop_request "$id" '{"protocol_version":1,"id":"'"$id"'","verb":"'"$verb"'","args":'"$args"',"created_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}'
  wait_for "rejection result for $verb" 10 has_result "$id"
  check "worker rejects: $bad_req" "$([ "$(result_status "$id")" = rejected ]; echo $?)"
done
check "no command was executed for rejected requests" "$([ "$(invocation_count)" -eq "$before" ]; echo $?)"

echo "== 8. timeout kills the job and propagates exit 124"
set_control "sleep_s=30"
started=$(date +%s)
out="$("$client" build --scheme Reader --timeout 2 2>&1)"; rc=$?
clear_control
check "client exits 124" "$([ "$rc" -eq 124 ]; echo $?)"
check "reported as timeout" "$(grep -q 'timeout' <<<"$out"; echo $?)"
check "finished promptly (<20s)" "$([ $(( $(date +%s) - started )) -lt 20 ]; echo $?)"
sleep 0.5
check "mock process group is dead" "$(! pgrep -f 'sleep 30' >/dev/null; echo $?)"

# Uses SIGTERM: bash starts background jobs with SIGINT ignored, so the client's
# INT trap is untrappable here; interactive Ctrl-C takes the same TERM/INT trap path.
echo "== 9. cancel signal stops the running job"
set_control "sleep_s=30"
"$client" build --scheme Reader >"$work/cancel-out.log" 2>&1 &
client_pid=$!
running_job=""
job_running() {
  local s
  for s in "$BRIDGE_DIR/jobs"/*/state; do
    if [ "$(cat "$s" 2>/dev/null)" = running ]; then
      running_job="$(basename "$(dirname "$s")")"
      return 0
    fi
  done
  return 1
}
wait_for "job running" 15 job_running
kill -TERM "$client_pid"
wait "$client_pid"; rc=$?
clear_control
job_id="$running_job"
check "client exits 130" "$([ "$rc" -eq 130 ]; echo $?)"
check "job result is cancelled" "$([ "$(result_status "$job_id")" = cancelled ]; echo $?)"
sleep 0.5
check "cancelled process group is dead" "$(! pgrep -f 'sleep 30' >/dev/null; echo $?)"

echo "== 10. bridge status reports dead worker"
kill "$worker_pid" 2>/dev/null; wait "$worker_pid" 2>/dev/null; worker_pid=""
rm -f "$BRIDGE_DIR/worker/heartbeat.json"
out="$("$client" status)"; rc=$?
check "status exit 1" "$([ "$rc" -eq 1 ]; echo $?)"
check "status says not running" "$(grep -q 'not running' <<<"$out"; echo $?)"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
