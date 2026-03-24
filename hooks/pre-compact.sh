#!/bin/bash
# Hook: PreCompact
# Fires when Claude Code is about to compact the conversation context.
# Posts a Discord notification so users know a compaction is happening.

set -euo pipefail

CHAT_ID="1485343472952148008"
SECRET="${DISCORD_INJECT_SECRET:-}"

if [ -z "$SECRET" ]; then
  # Try loading from .env
  ENV_FILE="$HOME/.claude/channels/discord/.env"
  if [ -f "$ENV_FILE" ]; then
    SECRET=$(grep -m1 '^DISCORD_INJECT_SECRET=' "$ENV_FILE" | cut -d= -f2-)
  fi
fi

MSG="🗜️ **Compacting context** — conversation is getting long, summarizing now. I'll be right back."

if [ -n "$SECRET" ]; then
  python3 -c "
import urllib.request, json, sys
req = urllib.request.Request(
  'http://127.0.0.1:9876/inject',
  data=json.dumps({'content': sys.argv[1], 'chat_id': sys.argv[2], 'user': 'system'}).encode(),
  headers={'Content-Type': 'application/json', 'x-inject-secret': sys.argv[3]},
  method='POST'
)
urllib.request.urlopen(req, timeout=5)
" "$MSG" "$CHAT_ID" "$SECRET" >/dev/null 2>&1 || true
fi

exit 0
