#!/usr/bin/env python3
"""
timeline_approve.py -- Review and approve/reject timeline candidates.

Reads from /mnt/data/hello-world/data/timeline-candidates.json,
merges approved entries into /mnt/data/hello-world/data/timeline.json,
and removes processed candidates.

Usage:
  python3 /mnt/data/scripts/timeline_approve.py                # interactive review
  python3 /mnt/data/scripts/timeline_approve.py --approve-all  # approve everything
  python3 /mnt/data/scripts/timeline_approve.py --list         # list candidates without acting
  python3 /mnt/data/scripts/timeline_approve.py --approve 0 2  # approve by index
  python3 /mnt/data/scripts/timeline_approve.py --reject 1 3   # reject by index
"""

import argparse
import json
import os
import subprocess
import sys

TIMELINE_PATH = "/mnt/data/hello-world/data/timeline.json"
CANDIDATES_PATH = "/mnt/data/hello-world/data/timeline-candidates.json"


def load_json(path: str) -> list[dict]:
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return json.load(f)


def save_json(path: str, data: list[dict]) -> None:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"Saved {len(data)} entries to {path}")


def merge_into_timeline(timeline: list[dict], approved: list[dict]) -> list[dict]:
    """Merge approved candidates into timeline, stripping ingestion-only fields."""
    strip_fields = {"repo", "reason", "sha"}
    for entry in approved:
        clean = {k: v for k, v in entry.items() if k not in strip_fields}
        timeline.append(clean)
    timeline.sort(key=lambda x: x.get("date", ""))
    return timeline


def commit_and_push():
    """Commit and push timeline.json changes."""
    cwd = "/mnt/data/hello-world"
    subprocess.run(["git", "add", "data/timeline.json"], cwd=cwd, check=True)
    result = subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=cwd)
    if result.returncode == 0:
        print("No changes to commit.")
        return
    subprocess.run(
        ["git", "commit", "-m", "timeline: add approved entries from ingestion"],
        cwd=cwd, check=True,
    )
    subprocess.run(["git", "push"], cwd=cwd, check=True)
    print("Committed and pushed timeline.json")


def display_candidates(candidates: list[dict]) -> None:
    if not candidates:
        print("No candidates to review.")
        return
    for i, c in enumerate(candidates):
        date = c.get("date", "?")[:10]
        repo = c.get("repo", "?")
        title = c.get("title", "?")
        reason = c.get("reason", "?")
        cat = c.get("category", "?")
        print(f"  [{i}] {date} | {repo} | {cat} | {title}")
        print(f"       reason: {reason}")
        if c.get("url"):
            print(f"       url: {c['url']}")
        print()


def main():
    parser = argparse.ArgumentParser(description="Approve/reject timeline candidates")
    parser.add_argument("--list", action="store_true", help="List candidates without acting")
    parser.add_argument("--approve-all", action="store_true", help="Approve all candidates")
    parser.add_argument("--approve", nargs="+", type=int, metavar="IDX", help="Approve by index")
    parser.add_argument("--reject", nargs="+", type=int, metavar="IDX", help="Reject by index")
    parser.add_argument("--no-push", action="store_true", help="Skip git commit/push")
    args = parser.parse_args()

    candidates = load_json(CANDIDATES_PATH)
    if not candidates:
        print("No candidates to review.")
        return

    print(f"\n{len(candidates)} timeline candidates:\n")
    display_candidates(candidates)

    if args.list:
        return

    if args.approve_all:
        approved = candidates
        remaining = []
    elif args.approve is not None or args.reject is not None:
        approve_set = set(args.approve or [])
        reject_set = set(args.reject or [])
        overlap = approve_set & reject_set
        if overlap:
            print(f"ERROR: indices {overlap} appear in both --approve and --reject", file=sys.stderr)
            sys.exit(1)
        approved = [candidates[i] for i in sorted(approve_set) if 0 <= i < len(candidates)]
        remaining = [
            c for i, c in enumerate(candidates)
            if i not in approve_set and i not in reject_set
        ]
    else:
        # Interactive mode
        approved = []
        remaining = []
        for i, c in enumerate(candidates):
            while True:
                choice = input(f"[{i}] {c.get('title', '?')[:60]} (a)pprove / (r)eject / (s)kip / (e)dit title? ").strip().lower()
                if choice in ("a", "approve"):
                    approved.append(c)
                    break
                elif choice in ("r", "reject"):
                    break  # drop it
                elif choice in ("s", "skip"):
                    remaining.append(c)
                    break
                elif choice in ("e", "edit"):
                    new_title = input("  New title: ").strip()
                    if new_title:
                        c["title"] = new_title
                    new_desc = input("  New description (enter to keep): ").strip()
                    if new_desc:
                        c["description"] = new_desc
                    approved.append(c)
                    break

    print(f"\nApproved: {len(approved)}, Remaining: {len(remaining)}")

    if approved:
        timeline = load_json(TIMELINE_PATH)
        timeline = merge_into_timeline(timeline, approved)
        save_json(TIMELINE_PATH, timeline)

    # Write back remaining candidates
    save_json(CANDIDATES_PATH, remaining)

    if approved and not args.no_push:
        commit_and_push()


if __name__ == "__main__":
    main()
