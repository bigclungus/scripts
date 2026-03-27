#!/usr/bin/env bash
# discord-watchdog.sh — checks that the discord plugin inject endpoint (port 9876) is alive.
# If port 9876 is not listening, logs the failure and restarts claude-bot.service.
# Runs every 3 minutes via cron.

LOG=/tmp/discord-watchdog.log

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# --- Primary check: port 9876 listening ---
if ss -tlnH 2>/dev/null | grep -q '127.0.0.1:9876'; then
  PORT_UP=1
elif lsof -iTCP:9876 -sTCP:LISTEN -n -P 2>/dev/null | grep -q .; then
  PORT_UP=1
else
  PORT_UP=0
fi

# --- Decision ---
if [ "$PORT_UP" -eq 1 ]; then
  echo "$(ts) OK port=up" >> "$LOG"
else
  echo "$(ts) FAIL port=down — restarting claude-bot.service" >> "$LOG"
  systemctl --user restart claude-bot.service
  RESTART_RC=$?
  if [ "$RESTART_RC" -eq 0 ]; then
    echo "$(ts) RESTARTED claude-bot.service successfully" >> "$LOG"
  else
    echo "$(ts) ERROR restart exited with code ${RESTART_RC}" >> "$LOG"
  fi
fi
