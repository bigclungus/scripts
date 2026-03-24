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

# Rate limit check — skip GitHub calls if we've hit the soft limit
RATELIMIT_FILE="/tmp/bc-gh-ratelimit.json"
RATELIMIT_MAX=200
RATELIMIT_WINDOW=3600
NOW_RL=$(date +%s)

RL_COUNT=0
RL_WINDOW_START=$NOW_RL

if [ -f "$RATELIMIT_FILE" ]; then
  RL_COUNT=$(jq -r '.count // 0' "$RATELIMIT_FILE" 2>/dev/null || echo 0)
  RL_WINDOW_START=$(jq -r '.window_start // 0' "$RATELIMIT_FILE" 2>/dev/null || echo 0)
  WINDOW_AGE=$(( NOW_RL - RL_WINDOW_START ))
  if [ "$WINDOW_AGE" -ge "$RATELIMIT_WINDOW" ]; then
    RL_COUNT=0
    RL_WINDOW_START=$NOW_RL
  fi
fi

if [ "$RL_COUNT" -ge "$RATELIMIT_MAX" ]; then
  echo "subagent-stop: rate limit reached ($RL_COUNT/$RATELIMIT_MAX in window), skipping GitHub" >&2
  exit 0
fi

# Increment counter
jq -n --argjson count "$((RL_COUNT + 1))" --argjson ws "$RL_WINDOW_START" \
  '{count: $count, window_start: $ws}' > "$RATELIMIT_FILE"

STATE_FILE="/tmp/bc-agents/${AGENT_ID}.json"

if [ ! -f "$STATE_FILE" ]; then
  echo "subagent-stop: no state file for $AGENT_ID — skipping" >&2
  exit 0
fi

ISSUE_NUMBER=$(jq -r '.issue_number' "$STATE_FILE")
ISSUE_NODE_ID=$(jq -r '.issue_node_id // empty' "$STATE_FILE")
ITEM_ID=$(jq -r '.item_id' "$STATE_FILE")
ISSUE_URL=$(jq -r '.issue_url' "$STATE_FILE")
STARTED=$(jq -r '.started' "$STATE_FILE")
AGENT_TYPE=$(jq -r '.agent_type' "$STATE_FILE")

# If node_id wasn't stored (legacy state files), fetch it
if [ -z "$ISSUE_NODE_ID" ] || [ "$ISSUE_NODE_ID" = "null" ]; then
  ISSUE_NODE_ID=$(gh issue view "$ISSUE_NUMBER" \
    --repo BigClungus/bigclungus-meta \
    --json nodeId --jq '.nodeId' 2>/dev/null || true)
fi

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

# Batch: close issue + set project status to Done in a single GraphQL call
if [ -n "$ISSUE_NODE_ID" ] && [ "$ISSUE_NODE_ID" != "null" ] \
   && [ -n "$ITEM_ID" ] && [ "$ITEM_ID" != "null" ]; then
  gh api graphql \
    -f query='mutation($issueId:ID!, $projectId:ID!, $itemId:ID!, $fieldId:ID!, $optionId:String!) {
      closeIssue(input:{issueId:$issueId, stateReason:COMPLETED}) {
        issue { id }
      }
      updateProjectV2ItemFieldValue(input:{projectId:$projectId, itemId:$itemId, fieldId:$fieldId, value:{singleSelectOptionId:$optionId}}) {
        projectV2Item { id }
      }
    }' \
    -f issueId="$ISSUE_NODE_ID" \
    -f projectId=PVT_kwHOEBqF8c4BSf-9 \
    -f itemId="$ITEM_ID" \
    -f fieldId=PVTSSF_lAHOEBqF8c4BSf-9zhAA8iU \
    -f optionId=98236657 2>/dev/null || {
      # Fallback: close and update separately if batch fails
      gh issue close "$ISSUE_NUMBER" --repo BigClungus/bigclungus-meta 2>/dev/null || true
      gh project item-edit \
        --project-id PVT_kwHOEBqF8c4BSf-9 \
        --id "$ITEM_ID" \
        --field-id PVTSSF_lAHOEBqF8c4BSf-9zhAA8iU \
        --single-select-option-id 98236657 2>/dev/null || true
    }
elif [ -n "$ISSUE_NODE_ID" ] && [ "$ISSUE_NODE_ID" != "null" ]; then
  # No item_id — just close the issue via GraphQL
  gh api graphql \
    -f query='mutation($issueId:ID!) {
      closeIssue(input:{issueId:$issueId, stateReason:COMPLETED}) {
        issue { id }
      }
    }' \
    -f issueId="$ISSUE_NODE_ID" 2>/dev/null || \
    gh issue close "$ISSUE_NUMBER" --repo BigClungus/bigclungus-meta 2>/dev/null || true
else
  # No node_id available — fall back to gh CLI
  gh issue close "$ISSUE_NUMBER" --repo BigClungus/bigclungus-meta 2>/dev/null || true
fi

# Clean up state file
rm -f "$STATE_FILE"

echo "subagent-stop: closed issue #$ISSUE_NUMBER for agent $AGENT_ID" >&2

exit 0
