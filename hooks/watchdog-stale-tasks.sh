#!/bin/bash
# Watchdog: marks in_progress tasks as stale if they've been running for >2 hours.
# Detects open tasks by: last log entry event == "started" AND ts is >2h ago.
# Backward compat: also handles old-format tasks with status: "in_progress".
# Run on bot restart or periodically to clean up orphaned task records.

set -euo pipefail

TASKS_DIR="/home/clungus/work/bigclungus-meta/tasks"
NOW_TS=$(date +%s)
STALE_COUNT=0
CHANGED=0

for task_file in "$TASKS_DIR"/*.json; do
  [ -f "$task_file" ] || continue
  [ "$(basename "$task_file")" = ".gitkeep" ] && continue

  # Determine if task is open via new log format or old status field
  LAST_LOG_EVENT=$(jq -r 'if (.log | length) > 0 then .log[-1].event else "" end' "$task_file")
  OLD_STATUS=$(jq -r '.status // ""' "$task_file")

  IS_OPEN=0
  STARTED_AT=""

  if [ "$LAST_LOG_EVENT" = "started" ]; then
    IS_OPEN=1
    # Use the "started" log entry's ts for age calculation
    STARTED_AT=$(jq -r '.log[] | select(.event == "started") | .ts' "$task_file" | head -1)
  elif [ -z "$LAST_LOG_EVENT" ] && [ "$OLD_STATUS" = "in_progress" ]; then
    # Backward compat: old format with no log array
    IS_OPEN=1
    STARTED_AT=$(jq -r '.started_at // ""' "$task_file")
  fi

  [ "$IS_OPEN" -eq 1 ] || continue
  [ -n "$STARTED_AT" ] || continue

  # Convert ISO8601 to epoch
  STARTED_TS=$(date -d "$STARTED_AT" +%s 2>/dev/null) || continue
  AGE_SECONDS=$(( NOW_TS - STARTED_TS ))

  # 2 hours = 7200 seconds
  if [ "$AGE_SECONDS" -ge 7200 ]; then
    STALE_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    TASK_ID=$(jq -r '.id // "(unknown)"' "$task_file")

    if [ -n "$LAST_LOG_EVENT" ]; then
      # New format: append stale log entry
      UPDATED=$(jq \
        --arg ts "$STALE_TS" \
        '.log += [{ts: $ts, event: "stale", context: "Marked stale by watchdog — session likely ended before task completed"}]' \
        "$task_file")
    else
      # Old format backward compat: update status fields
      UPDATED=$(jq \
        --arg status "stale" \
        --arg finished_at "$STALE_TS" \
        --arg summary "Marked stale by watchdog — session likely ended before task completed" \
        '.status = $status | .finished_at = $finished_at | .summary = $summary' \
        "$task_file")
    fi

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

# Check for stalled congress sessions (running > 2 hours)
STALLED_CONGRESS=$(temporal workflow list \
  --query 'WorkflowType="CongressWorkflow" AND ExecutionStatus="Running"' \
  --address localhost:7233 \
  --fields WorkflowId,StartTime \
  --output json 2>/dev/null | python3 -c "
import json, sys, datetime
try:
    workflows = json.load(sys.stdin)
    now = datetime.datetime.now(datetime.timezone.utc)
    stalled = []
    for wf in workflows:
        start = datetime.datetime.fromisoformat(wf.get('startTime', '').replace('Z', '+00:00'))
        age_hours = (now - start).total_seconds() / 3600
        if age_hours > 2:
            stalled.append(f\"{wf['workflowId']} ({age_hours:.1f}h)\")
    print(' '.join(stalled))
except Exception:
    pass
" 2>/dev/null)

if [ -n "$STALLED_CONGRESS" ]; then
    echo "STALLED_CONGRESS: $STALLED_CONGRESS"
fi
