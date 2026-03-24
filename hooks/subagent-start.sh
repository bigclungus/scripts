#!/bin/bash
# Hook: SubagentStart
# Fires when a subagent is spawned.
# Appends a JSON line to /tmp/bc-session-log.jsonl — no GitHub API calls at start time.
#
# Input JSON (stdin) fields:
#   agent_id        — unique ID for this subagent
#   agent_type      — agent type name (e.g. "Explore")
#   session_id      — parent session ID
#   hook_event_name — "SubagentStart"

set -euo pipefail

INPUT=$(cat)

AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "unknown"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

if [ -z "$AGENT_ID" ]; then
  exit 0
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
STATE_DIR="/tmp/bc-agents"
mkdir -p "$STATE_DIR"

# Try to find a pending prompt title (written by pre-agent-spawn.sh)
NOW_TS=$(date +%s)
TITLE=""
BEST_PENDING=""

for f in "$STATE_DIR"/pending-"${SESSION_ID}"-*; do
  [ -f "$f" ] || continue
  FILE_TS=$(jq -r '.ts // 0' "$f")
  AGE=$(( NOW_TS - FILE_TS ))
  if [ "$AGE" -le 30 ]; then
    TITLE=$(jq -r '.title // ""' "$f")
    BEST_PENDING="$f"
  fi
done

[ -n "$BEST_PENDING" ] && rm -f "$BEST_PENDING"

if [ -z "$TITLE" ]; then
  TITLE="${AGENT_TYPE} — ${AGENT_ID:0:12}"
fi

# Append to session log buffer (no GitHub calls)
LOG_LINE=$(jq -cn \
  --arg ts "$TIMESTAMP" \
  --arg agent_id "$AGENT_ID" \
  --arg agent_type "$AGENT_TYPE" \
  --arg session_id "$SESSION_ID" \
  --arg title "$TITLE" \
  '{ts: $ts, agent_id: $agent_id, agent_type: $agent_type, session_id: $session_id, title: $title, status: "started"}')

echo "$LOG_LINE" >> /tmp/bc-session-log.jsonl

echo "subagent-start: buffered $AGENT_ID ($AGENT_TYPE) to session log" >&2

exit 0
