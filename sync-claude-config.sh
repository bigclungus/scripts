#!/bin/bash
# Copies staged Claude config to ~/.claude before bot starts
STAGING="/mnt/data/claude-config"
DEST="$HOME/.claude"

for f in settings.json settings.local.json; do
  if [ -f "$STAGING/$f" ]; then
    cp "$STAGING/$f" "$DEST/$f"
    echo "Synced $f"
  fi
done

if [ -d "$STAGING/skills" ]; then
  rsync -a "$STAGING/skills/" "$DEST/skills/"
  echo "Synced skills/"
fi
