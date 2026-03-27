#!/usr/bin/env bash
# discord-watchdog.sh — checks that the discord plugin is alive and connected.
# Two checks:
#   1. Port 9876 listening (inject endpoint)
#   2. Discord bun process has active TCP connections to Discord gateway
# If either check fails, restarts claude-bot.service.
# Runs every 3 minutes via cron.

LOG=/tmp/discord-watchdog.log
COOLDOWN_FILE="/tmp/discord-watchdog-last-restart"
COOLDOWN_SECS=120  # 2-minute cooldown between restarts

ts() { date '+%Y-%m-%d %H:%M:%S'; }

restart_bot() {
  # Check cooldown
  if [ -f "$COOLDOWN_FILE" ]; then
    LAST=$(cat "$COOLDOWN_FILE")
    NOW=$(date +%s)
    ELAPSED=$(( NOW - LAST ))
    if [ "$ELAPSED" -lt "$COOLDOWN_SECS" ]; then
      echo "$(ts) SKIP restart (cooldown: ${ELAPSED}s < ${COOLDOWN_SECS}s)" >> "$LOG"
      return
    fi
  fi
  date +%s > "$COOLDOWN_FILE"
  systemctl --user restart claude-bot.service
  echo "$(ts) RESTART triggered, exit=$?" >> "$LOG"
}

# --- Check 1: port 9876 listening ---
if ss -tlnH 2>/dev/null | grep -q '127.0.0.1:9876'; then
  PORT_UP=1
elif lsof -iTCP:9876 -sTCP:LISTEN -n -P 2>/dev/null | grep -q .; then
  PORT_UP=1
else
  PORT_UP=0
fi

# --- Check 2: discord bun process has active gateway connections ---
# Find the bun process running the discord plugin
DISCORD_BUN_PID=$(pgrep -f "channels/discord" | head -1)

GATEWAY_CONNS=0
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
  restart_bot
elif [ "$GATEWAY_UP" -eq 0 ]; then
  echo "$(ts) FAIL gateway=disconnected (port=up, bun_pid=${DISCORD_BUN_PID}) — restarting claude-bot.service" >> "$LOG"
  restart_bot
fi
