#!/usr/bin/env bash
# discord-watchdog.sh — checks that the discord plugin inject endpoint (port 9876) is alive.
# If port 9876 is not listening, logs the failure and restarts claude-bot.service.
# Runs every 3 minutes via cron.

LOG=/tmp/discord-watchdog.log
INBOX_DIR="${HOME}/.claude/channels/discord/inbox"
STALE_MINUTES=5

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# --- Primary check: port 9876 listening ---
if ss -tlnH 2>/dev/null | grep -q '127.0.0.1:9876'; then
  PORT_UP=1
elif lsof -iTCP:9876 -sTCP:LISTEN -n -P 2>/dev/null | grep -q .; then
  PORT_UP=1
else
  PORT_UP=0
fi

# --- Secondary check: inbox staleness (informational only) ---
INBOX_STALE=0
if [ -d "$INBOX_DIR" ]; then
  NEWEST=$(find "$INBOX_DIR" -maxdepth 1 -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
  if [ -n "$NEWEST" ]; then
    NOW=$(date +%s)
    # Use integer math; NEWEST may have decimals — strip them
    NEWEST_INT=${NEWEST%.*}
    AGE=$(( NOW - NEWEST_INT ))
    STALE_SECS=$(( STALE_MINUTES * 60 ))
    if [ "$AGE" -gt "$STALE_SECS" ]; then
      INBOX_STALE=1
    fi
  fi
  # No files in inbox = quiet channel = normal. Not counted as stale.
fi

# --- Decision ---
if [ "$PORT_UP" -eq 1 ]; then
  echo "$(ts) OK port=up inbox_stale=${INBOX_STALE}" >> "$LOG"
else
  echo "$(ts) FAIL port=down inbox_stale=${INBOX_STALE} — restarting claude-bot.service" >> "$LOG"
  systemctl --user restart claude-bot.service
  RESTART_RC=$?
  if [ "$RESTART_RC" -eq 0 ]; then
    echo "$(ts) RESTARTED claude-bot.service successfully" >> "$LOG"
  else
    echo "$(ts) ERROR restart exited with code ${RESTART_RC}" >> "$LOG"
  fi
fi
