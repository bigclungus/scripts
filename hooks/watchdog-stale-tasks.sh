#!/bin/bash
# Watchdog: marks in_progress tasks as stale if they've been running for >2 hours.
# Detects open tasks by: no terminal event (done/failed/cancelled/stale) in log AND
# first log entry is >2h old. Backward compat: also handles old-format tasks with
# status: "in_progress". Run on bot restart or periodically to clean up orphaned records.

set -euo pipefail

TASKS_DIR="/home/clungus/work/bigclungus-meta/tasks"
NOW_TS=$(date +%s)
STALE_COUNT=0
CHANGED=0

for task_file in "$TASKS_DIR"/*.json; do
  [ -f "$task_file" ] || continue
  [ "$(basename "$task_file")" = ".gitkeep" ] && continue

  LOG_LEN=$(jq '.log | length' "$task_file" 2>/dev/null || echo 0)
  OLD_STATUS=$(jq -r '.status // ""' "$task_file")

  IS_OPEN=0
  STARTED_AT=""

  if [ "$LOG_LEN" -gt 0 ]; then
    # New format: open if log is non-empty AND contains no terminal event
    HAS_TERMINAL=$(jq -r '[.log[].event] | map(select(. == "done" or . == "failed" or . == "cancelled" or . == "stale")) | length' "$task_file")
    if [ "$HAS_TERMINAL" -eq 0 ]; then
      IS_OPEN=1
      # Use the FIRST log entry's ts for age (when the task was actually started)
      STARTED_AT=$(jq -r '.log[0].ts' "$task_file")
    fi
  elif [ "$LOG_LEN" -eq 0 ] && [ "$OLD_STATUS" = "in_progress" ]; then
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

    if [ "$LOG_LEN" -gt 0 ]; then
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

# Check for stalled congress sessions (running > 2 hours) and terminate them
temporal workflow list \
  --query 'WorkflowType="CongressWorkflow" AND ExecutionStatus="Running"' \
  --address localhost:7233 \
  --fields WorkflowId,StartTime \
  --output json 2>/dev/null | python3 -c "
import json, sys, datetime, subprocess

try:
    workflows = json.load(sys.stdin)
    now = datetime.datetime.now(datetime.timezone.utc)
    for wf in workflows:
        wf_id = wf.get('workflowId', '')
        start_str = wf.get('startTime', '')
        if not start_str:
            continue
        start = datetime.datetime.fromisoformat(start_str.replace('Z', '+00:00'))
        age_hours = (now - start).total_seconds() / 3600
        if age_hours > 2:
            print(f'Terminating stalled congress {wf_id} (running {age_hours:.1f}h)', flush=True)
            subprocess.run([
                'temporal', 'workflow', 'terminate',
                '--workflow-id', wf_id,
                '--address', 'localhost:7233',
                '--reason', f'Stalled: running {age_hours:.1f}h, terminated by watchdog'
            ], capture_output=True)
except Exception as e:
    print(f'Congress stall check error: {e}', file=sys.stderr)
" 2>/dev/null

# Also mark session JSONs for terminated congresses
python3 - <<'PYEOF'
import json, os, glob, datetime

sessions_dir = '/home/clungus/work/hello-world/sessions'
now = datetime.datetime.now(datetime.timezone.utc)

for path in glob.glob(f'{sessions_dir}/congress-*.json'):
    try:
        d = json.load(open(path))
        if d.get('status') != 'deliberating':
            continue
        started = d.get('started_at', '')
        if not started:
            continue
        start = datetime.datetime.fromisoformat(started.replace('Z', '+00:00'))
        age_hours = (now - start).total_seconds() / 3600
        if age_hours > 2:
            d['status'] = 'failed'
            d['failure_reason'] = f'Terminated by watchdog: stalled for {age_hours:.1f}h'
            json.dump(d, open(path, 'w'), indent=2)
            print(f'Marked stale: {os.path.basename(path)}')
    except Exception as e:
        pass
PYEOF
