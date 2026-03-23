#!/bin/bash
# Hook: SubagentStart
# Fires when a subagent is spawned.
# Creates a GitHub Project issue and stores the item ID in a temp file keyed by agent_id.
#
# Input JSON (stdin) fields:
#   agent_id       — unique ID for this subagent
#   agent_type     — agent type name (e.g. "Explore")
#   session_id     — parent session ID
#   hook_event_name — "SubagentStart"
#
# Reads pending prompt context from pre-agent-spawn.sh state files.
# State file written: /tmp/bc-agents/<agent_id>.json
#   Contains: { "issue_number": N, "item_id": "PVTI_...", "issue_url": "...", "started": "...", "agent_type": "..." }

set -euo pipefail

INPUT=$(cat)

AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "unknown"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

if [ -z "$AGENT_ID" ]; then
  exit 0
fi

STATE_DIR="/tmp/bc-agents"
mkdir -p "$STATE_DIR"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
NOW_TS=$(date +%s)

# Try to find the most recent pending prompt for this session (within last 10 seconds)
PENDING_TITLE=""
PENDING_PROMPT=""
BEST_PENDING=""

for f in "$STATE_DIR"/pending-"${SESSION_ID}"-*; do
  [ -f "$f" ] || continue
  FILE_TS=$(jq -r '.ts // 0' "$f")
  AGE=$(( NOW_TS - FILE_TS ))
  if [ "$AGE" -le 30 ]; then
    PENDING_TITLE=$(jq -r '.title // ""' "$f")
    PENDING_PROMPT=$(jq -r '.prompt // ""' "$f")
    BEST_PENDING="$f"
    # Take the most recent (last match — files are timestamp-sorted by name)
  fi
done

# Remove the pending file we consumed
[ -n "$BEST_PENDING" ] && rm -f "$BEST_PENDING"

# Build issue title
if [ -n "$PENDING_TITLE" ]; then
  TITLE="[subagent] ${PENDING_TITLE:0:80}"
else
  TITLE="[subagent] ${AGENT_TYPE} — ${AGENT_ID:0:12}"
fi

# Build issue body
BODY="**Agent ID**: \`${AGENT_ID}\`
**Agent Type**: \`${AGENT_TYPE}\`
**Session**: \`${SESSION_ID}\`
**Started**: ${TIMESTAMP}"

if [ -n "$PENDING_PROMPT" ]; then
  PROMPT_EXCERPT="${PENDING_PROMPT:0:1000}"
  if [ ${#PENDING_PROMPT} -gt 1000 ]; then
    PROMPT_EXCERPT="${PROMPT_EXCERPT}
...(truncated)"
  fi
  BODY="${BODY}

### Task Prompt

\`\`\`
${PROMPT_EXCERPT}
\`\`\`"
fi

BODY="${BODY}

_Auto-created by BigClungus subagent tracker hook._"

# Create GitHub issue
ISSUE_URL=$(gh issue create \
  --repo BigClungus/bigclungus-meta \
  --title "$TITLE" \
  --body "$BODY" \
  --label "automated,subagent" 2>/dev/null)

if [ -z "$ISSUE_URL" ]; then
  echo "subagent-start: failed to create issue for $AGENT_ID" >&2
  exit 0
fi

# Add to GitHub Project
ITEM_JSON=$(gh project item-add 1 --owner BigClungus --url "$ISSUE_URL" --format json 2>/dev/null)
ITEM_ID=$(echo "$ITEM_JSON" | jq -r '.id // empty')

if [ -n "$ITEM_ID" ]; then
  # Set status to "In Progress"
  gh project item-edit \
    --project-id PVT_kwHOEBqF8c4BSf-9 \
    --id "$ITEM_ID" \
    --field-id PVTSSF_lAHOEBqF8c4BSf-9zhAA8iU \
    --single-select-option-id 47fc9ee4 2>/dev/null || true
fi

ISSUE_NUMBER=$(echo "$ISSUE_URL" | grep -oP '\d+$')

# Persist state for SubagentStop
jq -n \
  --arg issue_number "$ISSUE_NUMBER" \
  --arg item_id "${ITEM_ID:-}" \
  --arg issue_url "$ISSUE_URL" \
  --arg agent_type "$AGENT_TYPE" \
  --arg started "$TIMESTAMP" \
  '{
    issue_number: ($issue_number | tonumber),
    item_id: $item_id,
    issue_url: $issue_url,
    agent_type: $agent_type,
    started: $started
  }' > "$STATE_DIR/${AGENT_ID}.json"

echo "subagent-start: tracked $AGENT_ID → issue #$ISSUE_NUMBER" >&2

exit 0
