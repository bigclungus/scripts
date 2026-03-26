#!/usr/bin/env python3
"""
Heartbeat reliability ideation scanner.

Runs during idle heartbeat cycles (when no services are down, no stale tasks,
no open issues). Checks for concrete operational reliability gaps and returns
a finding string if one is found, or None if everything looks clean.

Findings are used to fire a Congress with topic:
  [idea]: <finding>
"""

import subprocess
import re
import sys


def check_flaky_services() -> str | None:
    """
    Detect services that have restarted or failed recently (last 24h).
    A service that restarted multiple times in 24h is flaky.
    """
    result = subprocess.run(
        ["journalctl", "--user", "-n", "500", "--since", "24h ago",
         "--no-pager", "-o", "short"],
        capture_output=True, text=True, timeout=15
    )
    if result.returncode != 0:
        raise RuntimeError(f"journalctl failed: {result.stderr.strip()}")

    lines = result.stdout.splitlines()

    # Count "Started <service>" / "Stopped <service>" / "Failed <service>" events per unit
    restart_counts: dict[str, int] = {}
    failure_counts: dict[str, int] = {}

    started_re = re.compile(r"Started\s+(.+?)\.service", re.IGNORECASE)
    stopped_re = re.compile(r"Stopped\s+(.+?)\.service", re.IGNORECASE)
    failed_re  = re.compile(r"(Failed|failed with result)\s+.*?([a-zA-Z0-9_-]+)\.service", re.IGNORECASE)

    for line in lines:
        m = started_re.search(line)
        if m:
            svc = m.group(1).strip()
            restart_counts[svc] = restart_counts.get(svc, 0) + 1

        m = stopped_re.search(line)
        if m:
            svc = m.group(1).strip()
            restart_counts[svc] = restart_counts.get(svc, 0) + 1

        m = failed_re.search(line)
        if m:
            svc = m.group(2).strip()
            failure_counts[svc] = failure_counts.get(svc, 0) + 1

    # Flag services that restarted 3+ times (flaky) or failed 2+ times
    flaky = [s for s, n in restart_counts.items() if n >= 3]
    failing = [s for s, n in failure_counts.items() if n >= 2]

    if failing:
        top = sorted(failing, key=lambda s: failure_counts[s], reverse=True)[0]
        return f"service {top}.service has failed {failure_counts[top]}x in last 24h — investigate restart loop"

    if flaky:
        top = sorted(flaky, key=lambda s: restart_counts[s], reverse=True)[0]
        return f"service {top}.service restarted {restart_counts[top]}x in last 24h — possible flakiness"

    return None


def check_disk_usage() -> str | None:
    """Flag if root filesystem or /mnt/data is above 80%."""
    result = subprocess.run(["df", "-h", "/", "/mnt/data"], capture_output=True, text=True, timeout=10)
    if result.returncode != 0:
        raise RuntimeError(f"df failed: {result.stderr.strip()}")

    for line in result.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 6:
            continue
        pct_str = parts[4].rstrip("%")
        try:
            pct = int(pct_str)
        except ValueError:
            continue
        mountpoint = parts[5]
        if pct >= 80:
            return f"disk usage at {pct}% on {mountpoint} — getting close to full"

    return None


def check_temporal_retries() -> str | None:
    """
    Check for Temporal workflows with high attempt counts (>=5).
    Uses `temporal workflow list` and parses the output.
    """
    result = subprocess.run(
        ["temporal", "workflow", "list", "--limit", "20", "--no-pager"],
        capture_output=True, text=True, timeout=20
    )
    if result.returncode != 0:
        # Temporal may not be reachable; don't treat as fatal, just skip
        return None

    # Look for attempt counts in the output. The CLI prints lines like:
    #   Attempt: 7
    # or columns including attempt numbers depending on version.
    attempt_re = re.compile(r"Attempt[:\s]+(\d+)", re.IGNORECASE)
    workflow_re = re.compile(r"WorkflowId[:\s]+(\S+)", re.IGNORECASE)

    lines = result.stdout.splitlines()
    current_wf = None
    high_retry_wf = None
    high_retry_count = 0

    for line in lines:
        wm = workflow_re.search(line)
        if wm:
            current_wf = wm.group(1)

        am = attempt_re.search(line)
        if am:
            attempts = int(am.group(1))
            if attempts >= 5 and attempts > high_retry_count:
                high_retry_count = attempts
                high_retry_wf = current_wf

    if high_retry_wf:
        return f"Temporal workflow {high_retry_wf} has {high_retry_count} retry attempts — likely stuck or misconfigured"

    return None


def run() -> str | None:
    """
    Run all checks in priority order. Return the first concrete finding, or None.
    Checks run sequentially; first non-None result wins.
    """
    checks = [
        ("disk", check_disk_usage),
        ("flaky_services", check_flaky_services),
        ("temporal_retries", check_temporal_retries),
    ]

    for name, fn in checks:
        finding = fn()
        if finding is not None:
            return finding

    return None


if __name__ == "__main__":
    finding = run()
    if finding:
        print(finding)
        sys.exit(0)
    else:
        # No finding — exit with code 0 and no output
        sys.exit(0)
