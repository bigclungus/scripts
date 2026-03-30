#!/usr/bin/env python3
"""
memory-sweep-cron.py -- Pick the oldest unverified memory file and inject a sweep request.

Runs daily via systemd timer. Picks the single most stale file (>1 day old,
not verified in >7 days) and injects a [memory-sweep] message via omni webhook.
Exits silently if nothing qualifies -- no spam.
"""

import os
import sys
import json
import re
import urllib.request
import urllib.error
from datetime import datetime, timezone, timedelta
from pathlib import Path

MEMORY_DIR = Path("/home/clungus/.claude/projects/-mnt-data/memory")
LOCK_FILE = Path("/tmp/memory-sweep.lock")
OMNI_WEBHOOK = "http://127.0.0.1:8085/webhooks/bigclungus-main"

# Thresholds
MIN_AGE_DAYS = 1       # file must be at least this old (by mtime or creation)
MIN_STALE_DAYS = 7     # file must not have been verified within this many days


def parse_verified_date(content: str) -> datetime | None:
    """
    Look for a line like:
      > last verified: YYYY-MM-DD -- ...
    Returns a UTC datetime if found, else None.
    """
    match = re.search(r">\s*last verified:\s*(\d{4}-\d{2}-\d{2})", content)
    if not match:
        return None
    try:
        dt = datetime.strptime(match.group(1), "%Y-%m-%d")
        return dt.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def get_staleness_date(path: Path, content: str) -> datetime:
    """
    Returns the datetime representing when the file was last confirmed fresh.
    Priority: verified date from content > file mtime.
    """
    verified = parse_verified_date(content)
    if verified is not None:
        return verified
    mtime = os.path.getmtime(path)
    return datetime.fromtimestamp(mtime, tz=timezone.utc)


def main() -> None:
    now = datetime.now(tz=timezone.utc)

    # Lock check -- don't overlap runs
    if LOCK_FILE.exists():
        lock_age = now - datetime.fromtimestamp(LOCK_FILE.stat().st_mtime, tz=timezone.utc)
        if lock_age < timedelta(hours=2):
            print("Lock file exists and is recent -- another sweep is in progress. Exiting.")
            sys.exit(0)
        else:
            # Stale lock (>2h) -- remove and continue
            LOCK_FILE.unlink()

    # Collect candidates
    candidates: list[tuple[datetime, Path, str]] = []

    for path in sorted(MEMORY_DIR.glob("*.md")):
        if path.name == "MEMORY.md":
            continue

        content = path.read_text(encoding="utf-8")
        staleness_date = get_staleness_date(path, content)
        file_age = now - datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)

        # File must exist for at least MIN_AGE_DAYS
        if file_age < timedelta(days=MIN_AGE_DAYS):
            continue

        # Staleness date must be >MIN_STALE_DAYS ago
        if (now - staleness_date) < timedelta(days=MIN_STALE_DAYS):
            continue

        candidates.append((staleness_date, path, content))

    if not candidates:
        # Nothing stale enough -- exit silently
        sys.exit(0)

    # Pick the most stale file (oldest staleness_date)
    candidates.sort(key=lambda x: x[0])
    staleness_date, chosen_path, content = candidates[0]

    # Acquire lock
    LOCK_FILE.write_text(str(os.getpid()))

    try:
        payload = {
            "content": f"[memory-sweep] file={chosen_path.name}\n\nMEMORY CONTENT:\n{content}",
            "user": "memory-sweeper",
        }
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            OMNI_WEBHOOK,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            status = resp.status
            if status not in (200, 201, 202, 204):
                raise RuntimeError(f"Unexpected HTTP status from omni webhook: {status}")

        print(f"Injected memory-sweep for: {chosen_path.name} (last verified: {staleness_date.date()})")

    except urllib.error.URLError as e:
        # Remove lock so we can retry
        LOCK_FILE.unlink(missing_ok=True)
        raise RuntimeError(f"Failed to reach omni webhook at {OMNI_WEBHOOK}: {e}") from e
    except Exception:
        LOCK_FILE.unlink(missing_ok=True)
        raise

    # Note: lock is intentionally NOT removed here.
    # BigClungus's sweep handler removes it when verification is complete.
    # This prevents back-to-back sweeps of the same file if the cron fires again
    # before the agent finishes. The handler should call:
    #   rm -f /tmp/memory-sweep.lock
    # after writing the verified line back to the file.


if __name__ == "__main__":
    main()
