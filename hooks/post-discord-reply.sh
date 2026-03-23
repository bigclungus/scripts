#!/usr/bin/env bash
# PostToolUse hook for mcp__plugin_discord_discord__reply
# Reads the hook payload from stdin and forwards it to log-to-graphiti.py.
# Runs async (fire-and-forget) — errors are logged to stderr only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_GRAPHITI="${SCRIPT_DIR}/log-to-graphiti.py"

# Read stdin once
PAYLOAD="$(cat)"

# Delegate to Python script using the graphiti client directly.
# uv run picks up the mcp_server venv which has graphiti_core installed.
echo "${PAYLOAD}" | \
  /home/clungus/.local/bin/uv run \
    --project /home/clungus/work/graphiti/repo/mcp_server \
    python "${LOG_GRAPHITI}" 2>>/tmp/post-discord-reply.log || true
