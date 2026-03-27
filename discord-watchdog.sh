#!/usr/bin/env bash
# discord-watchdog.sh — checks that the discord plugin is alive and connected.
# Two checks:
#   1. Port 9876 listening (inject endpoint)
#   2. Discord bun process has active TCP connections to Discord gateway
# If either check fails, restarts claude-bot.service.
# Runs every 3 minutes via cron.

LOG=/tmp/discord-watchdog.log

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# --- Check 1: port 9876 listening ---
if ss -tlnH 2>/dev/null | grep -q '127.0.0.1:9876'; then
  PORT_UP=1
elif lsof -iTCP:9876 -sTCP:LISTEN -n -P 2>/dev/null | grep -q .; then
  PORT_UP=1
else
  PORT_UP=0
fi

# --- Check 2: discord bun process has active gateway connections ---
# Find the bun process running server.ts from the discord plugin directory
DISCORD_BUN_PID=$(pgrep -f "bun.*server\.ts" 2>/dev/null | head -1)

if [ -n "$DISCORD_BUN_PID" ]; then
  # Discord gateway uses Cloudflare IPs (162.159.x.x) on port 443
  # Check if the process has any established connections to Discord
  GATEWAY_CONNS=$(ss -tnp 2>/dev/null | grep "pid=${DISCORD_BUN_PID}" | grep -c "162\.159\.")
  if [ "$GATEWAY_CONNS" -gt 0 ]; then
    GATEWAY_UP=1
  else
    GATEWAY_UP=0
  fi
else
  # Can't find the bun process — treat as down
  GATEWAY_UP=0
fi

# --- Decision ---
if [ "$PORT_UP" -eq 1 ] && [ "$GATEWAY_UP" -eq 1 ]; then
  echo "$(ts) OK port=up gateway=connected(${GATEWAY_CONNS})" >> "$LOG"
elif [ "$PORT_UP" -eq 0 ]; then
  echo "$(ts) FAIL port=down — restarting claude-bot.service" >> "$LOG"
  systemctl --user restart claude-bot.service
  RESTART_RC=$?
  if [ "$RESTART_RC" -eq 0 ]; then
    echo "$(ts) RESTARTED claude-bot.service (port was down)" >> "$LOG"
  else
    echo "$(ts) ERROR restart exited with code ${RESTART_RC}" >> "$LOG"
  fi
elif [ "$GATEWAY_UP" -eq 0 ]; then
  echo "$(ts) FAIL gateway=disconnected (port=up, bun_pid=${DISCORD_BUN_PID}) — restarting claude-bot.service" >> "$LOG"
  systemctl --user restart claude-bot.service
  RESTART_RC=$?
  if [ "$RESTART_RC" -eq 0 ]; then
    echo "$(ts) RESTARTED claude-bot.service (gateway was disconnected)" >> "$LOG"
  else
    echo "$(ts) ERROR restart exited with code ${RESTART_RC}" >> "$LOG"
  fi
fi
