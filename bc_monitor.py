#!/usr/bin/env python3
"""
bc_monitor.py — BigClungus continuous monitoring daemon.
Polls every 60s, injects alerts to Discord when thresholds are exceeded.
"""

import json
import os
import subprocess
import time
import urllib.request
from datetime import datetime, timezone

import psutil

INJECT_URL = "http://127.0.0.1:9876/inject"
CHAT_ID = "1485343472952148008"
MONITOR_USER = "bc-monitor"
POLL_INTERVAL = 60  # seconds

DISK_THRESHOLD = 80  # percent
MEMORY_THRESHOLD = 85  # percent
FLAP_COUNT = 3  # restarts in window
FLAP_WINDOW = 600  # 10 minutes in seconds
STUCK_FAILED_MINUTES = 5
TEMPORAL_RETRY_THRESHOLD = 5

COOLDOWNS = {
    "disk": 3600,       # 1 hour
    "memory": 3600,     # 1 hour
    "flap": 1800,       # 30 minutes
    "failed": 900,      # 15 minutes
    "temporal": 3600,   # 1 hour
}

last_alerted: dict[str, float] = {}
failed_first_seen: dict[str, float] = {}


def load_inject_secret() -> str:
    secret = os.environ.get("DISCORD_INJECT_SECRET")
    if secret:
        return secret
    env_path = os.path.expanduser("~/.claude/channels/discord/.env")
    with open(env_path) as f:
        for line in f:
            if line.startswith("DISCORD_INJECT_SECRET"):
                return line.split("=", 1)[1].strip()
    raise RuntimeError("DISCORD_INJECT_SECRET not found")


def inject(secret: str, content: str) -> None:
    payload = json.dumps({"content": content, "chat_id": CHAT_ID, "user": MONITOR_USER}).encode()
    req = urllib.request.Request(
        INJECT_URL,
        data=payload,
        headers={"Content-Type": "application/json", "x-inject-secret": secret},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=5)
    except Exception as e:
        print(f"[{now()}] inject failed: {e}", flush=True)


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def should_alert(key: str, cooldown_type: str) -> bool:
    cooldown = COOLDOWNS[cooldown_type]
    last = last_alerted.get(key, 0)
    return (time.time() - last) >= cooldown


def mark_alerted(key: str) -> None:
    last_alerted[key] = time.time()


def check_disk(secret: str) -> None:
    for part in psutil.disk_partitions(all=False):
        mount = part.mountpoint
        if mount not in ("/", "/mnt/data"):
            continue
        try:
            usage = psutil.disk_usage(mount)
        except PermissionError:
            continue
        pct = usage.percent
        if pct > DISK_THRESHOLD:
            key = f"disk:{mount}"
            if should_alert(key, "disk"):
                inject(secret, f"⚠️ disk: {mount} at {pct:.1f}% (threshold: {DISK_THRESHOLD}%)")
                mark_alerted(key)
                print(f"[{now()}] alerted: disk {mount} at {pct:.1f}%", flush=True)


def check_memory(secret: str) -> None:
    mem = psutil.virtual_memory()
    pct = mem.percent
    if pct > MEMORY_THRESHOLD:
        key = "memory:system"
        if should_alert(key, "memory"):
            inject(secret, f"⚠️ memory: system at {pct:.1f}% (threshold: {MEMORY_THRESHOLD}%)")
            mark_alerted(key)
            print(f"[{now()}] alerted: memory at {pct:.1f}%", flush=True)


def get_user_services() -> list[str]:
    result = subprocess.run(
        ["systemctl", "--user", "list-units", "--type=service", "--no-pager", "--plain", "--all"],
        capture_output=True, text=True
    )
    services = []
    for line in result.stdout.splitlines():
        parts = line.split()
        if parts and parts[0].endswith(".service"):
            services.append(parts[0])
    return services


def check_flaps(secret: str) -> None:
    services = get_user_services()
    since_ts = f"{FLAP_WINDOW} seconds ago"
    for svc in services:
        try:
            result = subprocess.run(
                ["journalctl", "--user", "-u", svc, f"--since={since_ts}",
                 "--no-pager", "--output=short-monotonic", "-q"],
                capture_output=True, text=True, timeout=10
            )
        except subprocess.TimeoutExpired:
            continue
        starts = result.stdout.count("Started ")
        stops = result.stdout.count("Stopped ") + result.stdout.count("stopping")
        transitions = max(starts, stops)
        if transitions >= FLAP_COUNT:
            key = f"flap:{svc}"
            if should_alert(key, "flap"):
                inject(secret, f"⚠️ flap: {svc} started/stopped {transitions}x in last 10 min")
                mark_alerted(key)
                print(f"[{now()}] alerted: flap {svc} ({transitions} transitions)", flush=True)


def check_stuck_failed(secret: str) -> None:
    result = subprocess.run(
        ["systemctl", "--user", "list-units", "--type=service", "--state=failed",
         "--no-pager", "--plain", "--all"],
        capture_output=True, text=True
    )
    now_ts = time.time()
    currently_failed = set()
    for line in result.stdout.splitlines():
        parts = line.split()
        if parts and parts[0].endswith(".service"):
            svc = parts[0]
            currently_failed.add(svc)
            if svc not in failed_first_seen:
                failed_first_seen[svc] = now_ts
            duration = now_ts - failed_first_seen[svc]
            if duration >= STUCK_FAILED_MINUTES * 60:
                key = f"failed:{svc}"
                if should_alert(key, "failed"):
                    mins = int(duration // 60)
                    inject(secret, f"⚠️ stuck-failed: {svc} has been in failed state for {mins}m")
                    mark_alerted(key)
                    print(f"[{now()}] alerted: stuck-failed {svc} ({mins}m)", flush=True)

    # Clear first-seen for services no longer failed
    for svc in list(failed_first_seen.keys()):
        if svc not in currently_failed:
            del failed_first_seen[svc]


def check_temporal_retries(secret: str) -> None:
    try:
        result = subprocess.run(
            ["temporal", "workflow", "list", "--output", "json", "--limit", "50"],
            capture_output=True, text=True, timeout=15
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return
    if result.returncode != 0:
        return
    try:
        workflows = json.loads(result.stdout)
    except (json.JSONDecodeError, ValueError):
        # temporal list may output JSONL (one object per line)
        workflows = []
        for line in result.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                workflows.append(json.loads(line))
            except json.JSONDecodeError:
                continue

    for wf in workflows:
        if not isinstance(wf, dict):
            continue
        attempt = wf.get("attempt", 1)
        wf_id = wf.get("workflowId") or wf.get("workflow_id", "unknown")
        if attempt >= TEMPORAL_RETRY_THRESHOLD:
            key = f"temporal:{wf_id}"
            if should_alert(key, "temporal"):
                inject(secret, f"⚠️ temporal: workflow '{wf_id}' at attempt {attempt} (threshold: {TEMPORAL_RETRY_THRESHOLD})")
                mark_alerted(key)
                print(f"[{now()}] alerted: temporal {wf_id} attempt {attempt}", flush=True)


def main() -> None:
    print(f"[{now()}] bc-monitor starting (poll={POLL_INTERVAL}s)", flush=True)
    try:
        secret = load_inject_secret()
    except Exception as e:
        print(f"[{now()}] FATAL: could not load inject secret: {e}", flush=True)
        raise

    while True:
        try:
            check_disk(secret)
        except Exception as e:
            print(f"[{now()}] check_disk error: {e}", flush=True)
        try:
            check_memory(secret)
        except Exception as e:
            print(f"[{now()}] check_memory error: {e}", flush=True)
        try:
            check_flaps(secret)
        except Exception as e:
            print(f"[{now()}] check_flaps error: {e}", flush=True)
        try:
            check_stuck_failed(secret)
        except Exception as e:
            print(f"[{now()}] check_stuck_failed error: {e}", flush=True)
        try:
            check_temporal_retries(secret)
        except Exception as e:
            print(f"[{now()}] check_temporal_retries error: {e}", flush=True)

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
