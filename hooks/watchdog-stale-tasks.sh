#!/bin/bash
# Watchdog: marks in_progress tasks as stale if they've been running for >2 hours.
# Run on bot restart or periodically to clean up orphaned task records.

set -euo pipefail

TASKS_DIR="/home/clungus/work/bigclungus-meta/tasks"
NOW_TS=$(date +%s)
STALE_COUNT=0
CHANGED=0

for task_file in "$TASKS_DIR"/*.json; do
  [ -f "$task_file" ] || continue
  [ "$(basename "$task_file")" = ".gitkeep" ] && continue

  STATUS=$(jq -r '.status // ""' "$task_file")
  [ "$STATUS" = "in_progress" ] || continue

  STARTED_AT=$(jq -r '.started_at // ""' "$task_file")
  [ -n "$STARTED_AT" ] || continue

  # Convert ISO8601 to epoch
  STARTED_TS=$(date -d "$STARTED_AT" +%s 2>/dev/null) || continue
  AGE_SECONDS=$(( NOW_TS - STARTED_TS ))

  # 2 hours = 7200 seconds
  if [ "$AGE_SECONDS" -ge 7200 ]; then
    FINISHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    TASK_ID=$(jq -r '.id // "(unknown)"' "$task_file")

    UPDATED=$(jq \
      --arg status "stale" \
      --arg finished_at "$FINISHED_AT" \
      --arg summary "Marked stale by watchdog — session likely ended before task completed" \
      '.status = $status | .finished_at = $finished_at | .summary = $summary' \
      "$task_file")

    echo "$UPDATED" > "$task_file"
    STALE_COUNT=$(( STALE_COUNT + 1 ))
    CHANGED=1
    echo "watchdog: marked $TASK_ID as stale (age: ${AGE_SECONDS}s)" >&2
  fi
done

if [ "$CHANGED" -eq 1 ]; then
  (cd /home/clungus/work/bigclungus-meta && git add tasks/ && git commit -m "task: watchdog marked $STALE_COUNT stale" && git push)
fi

echo "watchdog: $STALE_COUNT task(s) marked stale"
