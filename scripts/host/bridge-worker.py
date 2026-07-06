#!/usr/bin/env python3
"""Host-side bridge worker: executes allowlisted Xcode commands for the dev container.

Polls .bridge/queue/ for JSON requests dropped by scripts/container/bridge, validates
them against a fixed verb table, runs the command via argv arrays (never a shell), and
streams output + result back through .bridge/jobs/<id>/. Protocol: docs/bridge.md.

Security invariants (do not weaken):
  - only verbs in VERBS run, built as argv lists, subprocess with shell=False
  - every argument value must match its regex and must not start with "-"
  - project paths are discovered under the repo root, never taken from requests
Runs on macOS (python3 from the Xcode Command Line Tools) and, for tests, on Linux.
"""

import fcntl
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

PROTOCOL_VERSION = 1
MAX_REQUEST_BYTES = 64 * 1024
POLL_INTERVAL = 0.5
HEARTBEAT_INTERVAL = 5
CLEANUP_INTERVAL = 600
STALE_REQUEST_AGE = timedelta(minutes=10)
STALE_JOB_AGE = timedelta(hours=24)
KILL_GRACE_SECONDS = 5

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,99}$")
DEST_VALUE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._()-]{0,99}$")
DEST_KEYS = {"platform", "name", "OS", "id", "arch"}
UDID_RE = re.compile(r"^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,99}$")


def now_utc():
    return datetime.now(timezone.utc)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


class Rejected(Exception):
    """Request failed validation."""


class Config:
    def __init__(self):
        script_dir = Path(__file__).resolve().parent
        self.repo_root = Path(
            os.environ.get("BRIDGE_REPO_ROOT", script_dir.parent.parent)
        ).resolve()
        self.bridge_dir = Path(
            os.environ.get("BRIDGE_DIR", self.repo_root / ".bridge")
        ).resolve()
        self.state_dir = Path(
            os.environ.get(
                "BRIDGE_STATE_DIR", Path.home() / "Library/Caches/reader-bridge"
            )
        ).resolve()
        self.xcodebuild = os.environ.get("BRIDGE_XCODEBUILD", "xcodebuild")
        self.xcrun = os.environ.get("BRIDGE_XCRUN", "xcrun")
        self.queue = self.bridge_dir / "queue"
        self.jobs = self.bridge_dir / "jobs"
        self.worker = self.bridge_dir / "worker"
        self.derived_data = self.state_dir / "DerivedData"


def validate_name(value, what):
    if not isinstance(value, str) or value.startswith("-") or not NAME_RE.match(value):
        raise Rejected(f"invalid {what}: {value!r}")
    return value


def validate_destination(value):
    if not isinstance(value, str) or value.startswith("-"):
        raise Rejected(f"invalid destination: {value!r}")
    pairs = []
    for part in value.split(","):
        key, sep, val = part.partition("=")
        key, val = key.strip(), val.strip()
        if not sep or key not in DEST_KEYS:
            raise Rejected(f"invalid destination key: {key!r}")
        if val.startswith("-") or not DEST_VALUE_RE.match(val):
            raise Rejected(f"invalid destination value: {val!r}")
        pairs.append(f"{key}={val}")
    return ",".join(pairs)


def validate_device(value):
    if isinstance(value, str) and not value.startswith("-") and (
        UDID_RE.match(value) or NAME_RE.match(value)
    ):
        return value
    raise Rejected(f"invalid device: {value!r}")


def discover_project(cfg):
    """Find the single .xcworkspace (preferred) or .xcodeproj at the repo root
    or one directory level below it (e.g. reader/reader.xcodeproj)."""
    for suffix, flag in ((".xcworkspace", "-workspace"), (".xcodeproj", "-project")):
        matches = sorted(
            p
            for pattern in (f"*{suffix}", f"*/*{suffix}")
            for p in cfg.repo_root.glob(pattern)
            # .xcodeproj bundles embed a project.xcworkspace; that one is not
            # a standalone workspace and must not shadow the project itself.
            if p.is_dir() and not p.parent.name.endswith(".xcodeproj")
        )
        if len(matches) > 1:
            raise Rejected(f"multiple {suffix} entries found; keep exactly one")
        if matches:
            path = matches[0].resolve()
            if cfg.repo_root not in path.parents:
                raise Rejected("project path escapes repo root")
            return [flag, str(path)]
    raise Rejected("no Xcode project found at repo root or one level below")


def xcodebuild_action(action, needs_destination):
    def build(cfg, args):
        argv = [cfg.xcodebuild, action] + discover_project(cfg)
        argv += ["-scheme", validate_name(args["scheme"], "scheme")]
        if "configuration" in args:
            argv += ["-configuration", validate_name(args["configuration"], "configuration")]
        if needs_destination and "destination" in args:
            argv += ["-destination", validate_destination(args["destination"])]
        argv += ["-derivedDataPath", str(cfg.derived_data)]
        return argv

    return build


# verb -> (builder(cfg, args) -> argv, required args, optional args, default/max timeout)
VERBS = {
    "xcode-version": {
        "build": lambda cfg, args: [cfg.xcodebuild, "-version"],
        "required": set(), "optional": set(), "timeout": 30, "max_timeout": 300,
    },
    "list-simulators": {
        "build": lambda cfg, args: [cfg.xcrun, "simctl", "list", "devices", "available"],
        "required": set(), "optional": set(), "timeout": 30, "max_timeout": 300,
    },
    "list-schemes": {
        "build": lambda cfg, args: [cfg.xcodebuild, "-list", "-json"] + discover_project(cfg),
        "required": set(), "optional": set(), "timeout": 60, "max_timeout": 300,
    },
    "build": {
        "build": xcodebuild_action("build", needs_destination=True),
        "required": {"scheme"}, "optional": {"configuration", "destination"},
        "timeout": 1800, "max_timeout": 7200,
    },
    "test": {
        "build": xcodebuild_action("test", needs_destination=True),
        "required": {"scheme"}, "optional": {"configuration", "destination"},
        "timeout": 2700, "max_timeout": 7200,
    },
    "clean": {
        "build": xcodebuild_action("clean", needs_destination=False),
        "required": {"scheme"}, "optional": set(), "timeout": 120, "max_timeout": 600,
    },
    "boot-simulator": {
        "build": lambda cfg, args: [cfg.xcrun, "simctl", "boot", validate_device(args["device"])],
        "required": {"device"}, "optional": set(), "timeout": 60, "max_timeout": 300,
        "ok_exit_codes": {0, 149},  # 149 = already booted
        "post": lambda cfg: [["open", "-a", "Simulator"]] if shutil.which("open") else [],
    },
}


def atomic_write(path, data):
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(data)
    os.rename(tmp, path)


def log_line(cfg, msg):
    line = f"{iso(now_utc())} {msg}"
    print(line, file=sys.stderr, flush=True)
    try:
        with open(cfg.state_dir / "worker.log", "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def child_env(cfg):
    env = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": os.environ.get("HOME", "/tmp"),
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    }
    if "DEVELOPER_DIR" in os.environ:
        env["DEVELOPER_DIR"] = os.environ["DEVELOPER_DIR"]
    # Test seam: mock shims live outside the fixed PATH and read control files.
    if "BRIDGE_CHILD_PATH_PREPEND" in os.environ:
        env["PATH"] = os.environ["BRIDGE_CHILD_PATH_PREPEND"] + ":" + env["PATH"]
    return env


def parse_request(cfg, job_dir):
    req_path = job_dir / "request.json"
    if req_path.stat().st_size > MAX_REQUEST_BYTES:
        raise Rejected("request exceeds 64 KB")
    try:
        req = json.loads(req_path.read_text())
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        raise Rejected(f"malformed JSON: {e}")
    if not isinstance(req, dict) or req.get("protocol_version") != PROTOCOL_VERSION:
        raise Rejected("unsupported protocol_version")
    verb = req.get("verb")
    if verb not in VERBS:
        raise Rejected(f"unknown verb: {verb!r}")
    spec = VERBS[verb]
    args = req.get("args", {})
    if not isinstance(args, dict):
        raise Rejected("args must be an object")
    keys = set(args)
    if not spec["required"] <= keys:
        raise Rejected(f"missing required args: {sorted(spec['required'] - keys)}")
    unknown = keys - spec["required"] - spec["optional"]
    if unknown:
        raise Rejected(f"unknown args: {sorted(unknown)}")
    timeout = req.get("timeout_seconds", spec["timeout"])
    if not isinstance(timeout, int) or isinstance(timeout, bool):
        raise Rejected("timeout_seconds must be an integer")
    timeout = max(1, min(timeout, spec["max_timeout"]))
    return req, spec, args, timeout


def write_result(job_dir, req_id, status, exit_code, started, error=None):
    result = {
        "protocol_version": PROTOCOL_VERSION,
        "id": req_id,
        "status": status,
        "exit_code": exit_code,
        "started_at": iso(started) if started else None,
        "finished_at": iso(now_utc()),
        "error": error,
    }
    atomic_write(job_dir / "result.json", json.dumps(result, indent=2) + "\n")
    atomic_write(job_dir / "state", "done\n")


def kill_group(proc):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            return
        deadline = time.monotonic() + KILL_GRACE_SECONDS
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                return
            time.sleep(0.1)


def run_commands(cfg, job_dir, argv_list, timeout, ok_exit_codes):
    """Run commands sequentially in the job's log; stop on first failure."""
    started = now_utc()
    deadline = time.monotonic() + timeout
    exit_code = 0
    with open(job_dir / "log", "ab") as log:
        for argv in argv_list:
            log_line(cfg, f"job {job_dir.name}: exec {argv}")
            proc = subprocess.Popen(
                argv, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                cwd=cfg.repo_root, env=child_env(cfg), start_new_session=True,
                shell=False,
            )
            atomic_write(job_dir / "state", "running\n")
            while proc.poll() is None:
                if (job_dir / "cancel").exists():
                    kill_group(proc)
                    return "cancelled", 130, started
                if time.monotonic() > deadline:
                    kill_group(proc)
                    return "timeout", 124, started
                time.sleep(min(1.0, POLL_INTERVAL))
            exit_code = proc.returncode
            if exit_code not in ok_exit_codes:
                return "done", exit_code, started
    return "done", 0 if exit_code in ok_exit_codes else exit_code, started


def run_job(cfg, job_dir):
    req_id = job_dir.name
    atomic_write(job_dir / "state", "claimed\n")
    started = None
    try:
        req, spec, args, timeout = parse_request(cfg, job_dir)
        if not ID_RE.match(str(req.get("id", ""))):
            raise Rejected("invalid request id")
        argv_list = [spec["build"](cfg, args)]
        if "post" in spec:
            argv_list += spec["post"](cfg)
        ok_exit_codes = spec.get("ok_exit_codes", {0})
    except Rejected as e:
        log_line(cfg, f"job {req_id}: rejected: {e}")
        write_result(job_dir, req_id, "rejected", 2, started, str(e))
        return
    try:
        status, exit_code, started = run_commands(
            cfg, job_dir, argv_list, timeout, ok_exit_codes
        )
        # Normalize accepted non-zero codes (e.g. simctl 149) to success.
        if status == "done" and exit_code in ok_exit_codes:
            exit_code = 0
        log_line(cfg, f"job {req_id}: {status} exit={exit_code}")
        write_result(job_dir, req_id, status, exit_code, started)
    except Exception as e:  # noqa: BLE001 — a broken job must not kill the worker
        log_line(cfg, f"job {req_id}: worker-error: {e}")
        write_result(job_dir, req_id, "worker-error", 1, started, str(e))


def write_heartbeat(cfg):
    atomic_write(
        cfg.worker / "heartbeat.json",
        json.dumps(
            {
                "pid": os.getpid(),
                "host": socket.gethostname(),
                "ts": iso(now_utc()),
                "mode": "mock" if "BRIDGE_XCODEBUILD" in os.environ else "real",
            }
        )
        + "\n",
    )


def reject_stale_queue_entry(cfg, entry):
    job_dir = cfg.jobs / entry.stem
    job_dir.mkdir(exist_ok=True)
    try:
        os.rename(entry, job_dir / "request.json")
    except FileNotFoundError:
        return
    log_line(cfg, f"job {entry.stem}: rejected: stale request")
    write_result(job_dir, entry.stem, "rejected", 2, None, "stale request")


def cleanup(cfg):
    cutoff = now_utc() - STALE_REQUEST_AGE
    for entry in sorted(cfg.queue.glob("*.json")):
        try:
            created = datetime.strptime(
                json.loads(entry.read_text()).get("created_at", ""),
                "%Y-%m-%dT%H:%M:%SZ",
            ).replace(tzinfo=timezone.utc)
        except (ValueError, json.JSONDecodeError, OSError):
            created = datetime.min.replace(tzinfo=timezone.utc)
        if created < cutoff:
            reject_stale_queue_entry(cfg, entry)
    job_cutoff = time.time() - STALE_JOB_AGE.total_seconds()
    for job_dir in cfg.jobs.iterdir() if cfg.jobs.exists() else []:
        try:
            if job_dir.is_dir() and job_dir.stat().st_mtime < job_cutoff:
                shutil.rmtree(job_dir, ignore_errors=True)
        except OSError:
            pass


def finish_orphaned_jobs(cfg):
    """Jobs left non-done by a previous worker crash get a terminal result."""
    for job_dir in cfg.jobs.iterdir() if cfg.jobs.exists() else []:
        state_path = job_dir / "state"
        if not job_dir.is_dir() or not state_path.exists():
            continue
        if state_path.read_text().strip() != "done":
            log_line(cfg, f"job {job_dir.name}: orphaned by worker restart")
            write_result(job_dir, job_dir.name, "worker-error", 1, None,
                         "worker restarted while job was active")


def main():
    cfg = Config()
    for d in (cfg.queue, cfg.jobs, cfg.worker, cfg.state_dir, cfg.derived_data):
        d.mkdir(parents=True, exist_ok=True)
    lock = open(cfg.state_dir / "worker.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("bridge-worker: another worker already holds the lock; exiting.",
              file=sys.stderr)
        return 1
    log_line(cfg, f"worker started pid={os.getpid()} repo={cfg.repo_root} "
                  f"bridge={cfg.bridge_dir}")
    finish_orphaned_jobs(cfg)
    cleanup(cfg)
    write_heartbeat(cfg)
    last_heartbeat = last_cleanup = time.monotonic()
    while True:
        now = time.monotonic()
        if now - last_heartbeat >= HEARTBEAT_INTERVAL:
            write_heartbeat(cfg)
            last_heartbeat = now
        if now - last_cleanup >= CLEANUP_INTERVAL:
            cleanup(cfg)
            last_cleanup = now
        entries = sorted(cfg.queue.glob("*.json"))
        if not entries:
            time.sleep(POLL_INTERVAL)
            continue
        entry = entries[0]
        if not ID_RE.match(entry.stem):
            entry.unlink(missing_ok=True)
            log_line(cfg, f"dropped queue entry with unsafe name: {entry.name!r}")
            continue
        job_dir = cfg.jobs / entry.stem
        job_dir.mkdir(exist_ok=True)
        try:
            os.rename(entry, job_dir / "request.json")  # atomic claim
        except FileNotFoundError:
            continue
        run_job(cfg, job_dir)
        write_heartbeat(cfg)
        last_heartbeat = time.monotonic()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("bridge-worker: interrupted, exiting.", file=sys.stderr)
        sys.exit(130)
