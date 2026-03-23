#!/bin/bash
# Hook: SubagentStop
# Fires when a subagent finishes.
# Reads state written by subagent-start.sh, updates issue with result summary,
# sets project item to Done, and closes the issue.
#
# Input JSON (stdin) fields relevant to us:
#   agent_id              — same ID as SubagentStart
#   agent_type            — agent type
#   last_assistant_message — final text output of the subagent
#   hook_event_name       — "SubagentStop"
#
# State file: /tmp/bc-agents/<agent_id>.json (written by subagent-start.sh)

set -euo pipefail

INPUT=$(cat)

AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""')

if [ -z "$AGENT_ID" ]; then
  exit 0
fi

STATE_FILE="/tmp/bc-agents/${AGENT_ID}.json"

if [ ! -f "$STATE_FILE" ]; then
  echo "subagent-stop: no state file for $AGENT_ID — skipping" >&2
  exit 0
fi

ISSUE_NUMBER=$(jq -r '.issue_number' "$STATE_FILE")
ITEM_ID=$(jq -r '.item_id' "$STATE_FILE")
ISSUE_URL=$(jq -r '.issue_url' "$STATE_FILE")
STARTED=$(jq -r '.started' "$STATE_FILE")
AGENT_TYPE=$(jq -r '.agent_type' "$STATE_FILE")

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Truncate last message to 2000 chars to avoid massive issue bodies
SUMMARY="${LAST_MSG:0:2000}"
if [ ${#LAST_MSG} -gt 2000 ]; then
  SUMMARY="${SUMMARY}
...(truncated)"
fi

COMMENT="**Completed**: ${TIMESTAMP}
**Started**: ${STARTED}

### Final Output

\`\`\`
${SUMMARY}
\`\`\`

_Auto-updated by BigClungus subagent tracker hook._"

# Post comment with result
gh issue comment "$ISSUE_NUMBER" \
  --repo BigClungus/bigclungus-meta \
  --body "$COMMENT" 2>/dev/null || true

# Set project item to Done
if [ -n "$ITEM_ID" ] && [ "$ITEM_ID" != "null" ]; then
  gh project item-edit \
    --project-id PVT_kwHOEBqF8c4BSf-9 \
    --id "$ITEM_ID" \
    --field-id PVTSSF_lAHOEBqF8c4BSf-9zhAA8iU \
    --single-select-option-id 98236657 2>/dev/null || true
fi

# Close the issue
gh issue close "$ISSUE_NUMBER" \
  --repo BigClungus/bigclungus-meta \
  --comment "Subagent finished." 2>/dev/null || true

# Clean up state file
rm -f "$STATE_FILE"

echo "subagent-stop: closed issue #$ISSUE_NUMBER for agent $AGENT_ID" >&2

exit 0
