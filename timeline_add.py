#!/usr/bin/env python3
"""
timeline_add.py -- Add a timeline entry directly (used by [timeline] Discord trigger).

Usage:
  python3 /mnt/data/scripts/timeline_add.py "Launched the thing" --category feature --url https://...
  python3 /mnt/data/scripts/timeline_add.py "Something happened" --source discord
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

TIMELINE_PATH = "/mnt/data/hello-world/data/timeline.json"

CATEGORY_KEYWORDS = {
    "infrastructure": re.compile(r"\b(infra|deploy|server|service|proxy|auth|migrate|tunnel|docker|systemd)\b", re.I),
    "congress-system": re.compile(r"\b(congress|persona|trial|debate|verdict|chairman)\b", re.I),
    "labs": re.compile(r"\b(lab|experiment)\b", re.I),
    "feature": re.compile(r"\b(add|feature|implement|create|new|ship|launch|build)\b", re.I),
    "succession": re.compile(r"\b(succession|restart|handoff|transfer)\b", re.I),
}


def auto_categorize(text: str) -> str:
    for cat, pattern in CATEGORY_KEYWORDS.items():
        if pattern.search(text):
            return cat
    return "milestone"


def main():
    parser = argparse.ArgumentParser(description="Add a timeline entry")
    parser.add_argument("description", help="Event description (becomes title)")
    parser.add_argument("--category", default=None, help="Category (auto-detected if omitted)")
    parser.add_argument("--url", default=None, help="Source URL")
    parser.add_argument("--source", default="manual", choices=["manual", "discord", "git"], help="Provenance")
    parser.add_argument("--date", default=None, help="ISO date (default: now)")
    parser.add_argument("--icon", default=None, help="Lucide icon name")
    parser.add_argument("--no-push", action="store_true", help="Skip git commit/push")
    args = parser.parse_args()

    # Load existing timeline
    if os.path.exists(TIMELINE_PATH):
        with open(TIMELINE_PATH) as f:
            timeline = json.load(f)
    else:
        timeline = []

    category = args.category or auto_categorize(args.description)
    date = args.date or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    entry = {
        "date": date,
        "title": args.description,
        "description": args.description,
        "category": category,
        "source": args.source,
    }
    if args.url:
        entry["url"] = args.url
    if args.icon:
        entry["icon"] = args.icon

    timeline.append(entry)
    timeline.sort(key=lambda x: x.get("date", ""))

    with open(TIMELINE_PATH, "w") as f:
        json.dump(timeline, f, indent=2)

    print(f"Added timeline entry: {args.description}")
    print(f"  category: {category}, source: {args.source}, date: {date}")

    if not args.no_push:
        cwd = "/mnt/data/hello-world"
        subprocess.run(["git", "add", "data/timeline.json"], cwd=cwd, check=True)
        result = subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=cwd)
        if result.returncode != 0:
            subprocess.run(
                ["git", "commit", "-m", f"timeline: {args.description[:60]}"],
                cwd=cwd, check=True,
            )
            subprocess.run(["git", "push"], cwd=cwd, check=True)
            print("Committed and pushed.")

    return entry


if __name__ == "__main__":
    main()
