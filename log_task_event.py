#!/usr/bin/env python3
"""Append a log event to a task JSON file.

Usage: python3 log_task_event.py <task_id_or_file> <event_type> <message>

event_type: started | milestone | user_feedback | blocked | done | failed
task_id_or_file: either a task ID like "task-20260324-..." or a full path
"""
import sys, json, os, re
from datetime import datetime, timezone
from pathlib import Path
import glob as _glob

# Patterns that suggest a credential is being logged
_CRED_PATTERNS = [
    re.compile(r'(?i)(password|passwd|api[_-]?key|apikey|token|secret|credential)[s]?\s*[=:]'),
    re.compile(r'(?i)bearer\s+[A-Za-z0-9\-_.~+/]{20,}'),
    # Long high-entropy alphanumeric strings (30+ chars, mix of cases/digits/symbols)
    re.compile(r'[A-Za-z0-9!@#$%^&*\-_.]{30,}'),
]

def _looks_like_credential(message: str) -> bool:
    for pattern in _CRED_PATTERNS:
        if pattern.search(message):
            return True
    return False

TASKS_DIR = "/home/clungus/work/bigclungus-meta/tasks"

def find_task_file(task_id_or_file: str) -> str:
    if os.path.isfile(task_id_or_file):
        return task_id_or_file
    # Try direct match
    direct = os.path.join(TASKS_DIR, task_id_or_file + ".json")
    if os.path.isfile(direct):
        return direct
    # Try prefix match
    matches = _glob.glob(os.path.join(TASKS_DIR, f"{task_id_or_file}*.json"))
    if matches:
        return matches[0]
    raise FileNotFoundError(f"No task file found for: {task_id_or_file}")

def main():
    if len(sys.argv) < 4:
        print("Usage: log_task_event.py <task_id_or_file> <event_type> <message>")
        sys.exit(1)

    task_ref, event_type, message = sys.argv[1], sys.argv[2], sys.argv[3]

    if _looks_like_credential(message):
        print("ERROR: Message looks like it may contain credentials or sensitive data.")
        print("Task files are committed to a public GitHub repo — do not log secrets.")
        print("If this is a false positive, shorten or redact the sensitive-looking portion.")
        sys.exit(1)

    path = find_task_file(task_ref)

    data = json.load(open(path))
    if "log" not in data:
        data["log"] = []

    entry = {
        "event": event_type,
        "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "message": message
    }
    data["log"].append(entry)

    # Also update status field for done/failed/blocked events
    if event_type in ("done", "failed"):
        data["status"] = event_type
    elif event_type == "blocked":
        data["status"] = "blocked"

    json.dump(data, open(path, "w"), indent=2)
    print(f"Logged [{event_type}] to {os.path.basename(path)}: {message}")

if __name__ == "__main__":
    main()
