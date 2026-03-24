#!/usr/bin/env python3
"""Append a log event to a task JSON file.

Usage: python3 log_task_event.py <task_id_or_file> <event_type> <message>

event_type: started | milestone | user_feedback | blocked | done | failed
task_id_or_file: either a task ID like "task-20260324-..." or a full path
"""
import sys, json, os
from datetime import datetime, timezone
from pathlib import Path
import glob as _glob

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
