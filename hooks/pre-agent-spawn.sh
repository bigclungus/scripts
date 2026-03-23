#!/bin/bash
# Hook: PreToolUse (matcher: "Agent")
# Fires before an Agent tool call executes — i.e., just before a subagent spawns.
# We cannot get the agent_id yet (it's assigned after spawn), but we CAN read the prompt.
#
# Strategy: write the prompt to /tmp/bc-pending-agent-prompt keyed by session+timestamp,
# then SubagentStart picks it up (matching on recency). This is a best-effort association.
#
# Alternatively (and more cleanly): use updatedInput to INJECT a unique tracking ID
# into the subagent's prompt, which the subagent will include in any gh issue it creates.
# That approach requires the subagent to cooperate (CLAUDE.md instruction).
#
# This hook does the simpler thing: saves the prompt so SubagentStart can use it
# as the issue title instead of the generic "agent_type + agent_id" title.
#
# Input JSON fields:
#   session_id      — current session
#   tool_name       — "Agent"
#   tool_input.prompt      — the prompt being sent to the subagent
#   tool_input.description — short description if provided
#   tool_input.subagent_type — e.g. "Explore"
#   hook_event_name — "PreToolUse"
#   agent_id        — present if THIS hook fires inside a subagent

set -euo pipefail

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only handle Agent tool calls
if [ "$TOOL_NAME" != "Agent" ]; then
  exit 0
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // ""')
DESCRIPTION=$(echo "$INPUT" | jq -r '.tool_input.description // ""')
SUBAGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // "unknown"')

# Use description as title if available, else first 80 chars of prompt
if [ -n "$DESCRIPTION" ]; then
  TITLE="$DESCRIPTION"
else
  TITLE="${PROMPT:0:80}"
  # Clean up newlines
  TITLE=$(echo "$TITLE" | tr '\n' ' ' | sed 's/  */ /g')
fi

STATE_DIR="/tmp/bc-agents"
mkdir -p "$STATE_DIR"

# Write pending prompt state — SubagentStart will consume it
# Use session_id + nanosecond timestamp to avoid collisions
PENDING_FILE="$STATE_DIR/pending-${SESSION_ID}-$(date +%s%N)"
jq -n \
  --arg title "$TITLE" \
  --arg prompt "$PROMPT" \
  --arg subagent_type "$SUBAGENT_TYPE" \
  --arg session_id "$SESSION_ID" \
  --argjson ts "$(date +%s)" \
  '{
    title: $title,
    prompt: $prompt,
    subagent_type: $subagent_type,
    session_id: $session_id,
    ts: $ts
  }' > "$PENDING_FILE"

echo "pre-agent-spawn: saved pending prompt for session $SESSION_ID" >&2

# Allow the agent to proceed without modification
exit 0
