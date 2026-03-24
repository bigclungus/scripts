#!/bin/bash
# Hook: SubagentStop
# Fires when a subagent finishes.
# Appends a "done" entry to /tmp/bc-session-log.jsonl, then flushes pending
# buffer entries to a single rolling GitHub issue for the session.
#
# Session issue state: /tmp/bc-session-issue.json
#   Contains: { "issue_number": N, "item_id": "PVTI_..." }
#
# On first stop of the session: create issue + add to project (2 API calls total).
# On subsequent stops: edit existing issue body (1 API call).
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

# Truncate summary to avoid massive issue bodies
SUMMARY="${LAST_MSG:0:500}"
if [ ${#LAST_MSG} -gt 500 ]; then
  SUMMARY="${SUMMARY}...(truncated)"
fi

# Append done entry to session log buffer
LOG_LINE=$(jq -cn \
  --arg ts "$TIMESTAMP" \
  --arg agent_id "$AGENT_ID" \
  --arg agent_type "$AGENT_TYPE" \
  --arg summary "$SUMMARY" \
  '{ts: $ts, agent_id: $agent_id, agent_type: $agent_type, summary: $summary, status: "done"}')

echo "$LOG_LINE" >> /tmp/bc-session-log.jsonl

# Build the issue body from all buffered log entries
build_issue_body() {
  local log_file="/tmp/bc-session-log.jsonl"
  local body="# BigClungus Session Log\n\n_Auto-updated by subagent hooks. One rolling issue per session._\n\n"
  body+="| Time | Agent | Type | Status | Summary |\n"
  body+="|------|-------|------|--------|---------|\n"

  while IFS= read -r line; do
    local ts agent_id agent_type status summary title
    ts=$(echo "$line" | jq -r '.ts // ""')
    agent_id=$(echo "$line" | jq -r '.agent_id // ""')
    agent_type=$(echo "$line" | jq -r '.agent_type // ""')
    status=$(echo "$line" | jq -r '.status // ""')
    summary=$(echo "$line" | jq -r '.summary // (.title // "")' | tr '\n' ' ' | cut -c1-80)

    body+="| ${ts} | \`${agent_id:0:12}\` | ${agent_type} | ${status} | ${summary} |\n"
  done < "$log_file"

  printf "%b" "$body"
}

SESSION_ISSUE_FILE="/tmp/bc-session-issue.json"

if [ -f "$SESSION_ISSUE_FILE" ]; then
  # Session issue already exists — update it with current log
  ISSUE_NUMBER=$(jq -r '.issue_number' "$SESSION_ISSUE_FILE")
  ISSUE_BODY=$(build_issue_body)

  gh issue edit "$ISSUE_NUMBER" \
    --repo BigClungus/bigclungus-meta \
    --body "$ISSUE_BODY" 2>/dev/null || true

  echo "subagent-stop: updated session issue #$ISSUE_NUMBER for agent $AGENT_ID" >&2
else
  # First stop of the session — create the session issue
  SESSION_DATE=$(date -u +"%Y-%m-%d")
  ISSUE_TITLE="[session] BigClungus subagent log — ${SESSION_DATE}"
  ISSUE_BODY=$(build_issue_body)

  ISSUE_JSON=$(gh issue create \
    --repo BigClungus/bigclungus-meta \
    --title "$ISSUE_TITLE" \
    --body "$ISSUE_BODY" \
    --label "automated,subagent" \
    --json nodeId,url,number 2>/dev/null)

  ISSUE_NUMBER=$(echo "$ISSUE_JSON" | jq -r '.number // empty')
  ISSUE_NODE_ID=$(echo "$ISSUE_JSON" | jq -r '.nodeId // empty')

  if [ -z "$ISSUE_NUMBER" ]; then
    echo "subagent-stop: failed to create session issue" >&2
    exit 0
  fi

  # Add to GitHub Project and set status "In Progress"
  ITEM_ID=$(gh api graphql \
    -f query='mutation($projectId:ID!, $issueId:ID!) {
      addProjectV2ItemById(input:{projectId:$projectId, contentId:$issueId}) {
        item { id }
      }
    }' \
    -f projectId=PVT_kwHOEBqF8c4BSf-9 \
    -f issueId="$ISSUE_NODE_ID" \
    --jq '.data.addProjectV2ItemById.item.id' 2>/dev/null || true)

  if [ -n "$ITEM_ID" ] && [ "$ITEM_ID" != "null" ]; then
    gh api graphql \
      -f query='mutation($projectId:ID!, $itemId:ID!, $fieldId:ID!, $optionId:String!) {
        updateProjectV2ItemFieldValue(input:{projectId:$projectId, itemId:$itemId, fieldId:$fieldId, value:{singleSelectOptionId:$optionId}}) {
          projectV2Item { id }
        }
      }' \
      -f projectId=PVT_kwHOEBqF8c4BSf-9 \
      -f itemId="$ITEM_ID" \
      -f fieldId=PVTSSF_lAHOEBqF8c4BSf-9zhAA8iU \
      -f optionId=47fc9ee4 2>/dev/null || true
  fi

  # Save session issue state
  jq -n \
    --argjson issue_number "$ISSUE_NUMBER" \
    --arg item_id "${ITEM_ID:-}" \
    --arg issue_node_id "${ISSUE_NODE_ID:-}" \
    '{issue_number: $issue_number, item_id: $item_id, issue_node_id: $issue_node_id}' \
    > "$SESSION_ISSUE_FILE"

  echo "subagent-stop: created session issue #$ISSUE_NUMBER for agent $AGENT_ID" >&2
fi

exit 0
