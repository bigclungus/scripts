#!/bin/bash
# Hook: SubagentStop
# Fires when a subagent finishes.
# Updates the task JSON file: status=done, finished_at=now, summary=first 500 chars of last message.
# Async git commit+push. Zero GitHub API calls.
#
# Input JSON (stdin) fields:
#   agent_id              — same ID as SubagentStart
#   agent_type            — agent type
#   last_assistant_message — final text output of the subagent
#   hook_event_name       — "SubagentStop"

set -euo pipefail

INPUT=$(cat)

AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "unknown"')
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""')

if [ -z "$AGENT_ID" ]; then
  exit 0
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
STATE_DIR="/tmp/bc-agents"

# Read agent state file to get task ID
AGENT_STATE_FILE="$STATE_DIR/${AGENT_ID}.json"
if [ ! -f "$AGENT_STATE_FILE" ]; then
  echo "subagent-stop: no state file found for agent $AGENT_ID, skipping task update" >&2
  exit 0
fi

TASK_ID=$(jq -r '.task_id // empty' "$AGENT_STATE_FILE")
if [ -z "$TASK_ID" ]; then
  echo "subagent-stop: no task_id in state file for agent $AGENT_ID, skipping" >&2
  exit 0
fi

TASKS_DIR="/home/clungus/work/bigclungus-meta/tasks"
TASK_FILE="$TASKS_DIR/${TASK_ID}.json"

if [ ! -f "$TASK_FILE" ]; then
  echo "subagent-stop: task file $TASK_FILE not found, skipping update" >&2
  exit 0
fi

# Truncate summary to 500 chars
SUMMARY="${LAST_MSG:0:500}"
if [ ${#LAST_MSG} -gt 500 ]; then
  SUMMARY="${SUMMARY}...(truncated)"
fi

# Update the task JSON: set status=done, finished_at, summary
UPDATED=$(jq \
  --arg status "done" \
  --arg finished_at "$TIMESTAMP" \
  --arg summary "$SUMMARY" \
  '.status = $status | .finished_at = $finished_at | .summary = $summary' \
  "$TASK_FILE")

echo "$UPDATED" > "$TASK_FILE"

# Clean up agent state file
rm -f "$AGENT_STATE_FILE"

# Async background git commit+push (zero blocking)
(cd /home/clungus/work/bigclungus-meta && git add tasks/ && git commit -m "task: done $TASK_ID" && git push) &

echo "subagent-stop: marked task $TASK_ID done for agent $AGENT_ID" >&2

exit 0
