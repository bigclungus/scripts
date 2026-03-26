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

if [ -f "$STAGING/installed_plugins.json" ]; then
  cp "$STAGING/installed_plugins.json" "$DEST/plugins/installed_plugins.json"
  echo "Synced plugins/installed_plugins.json"
fi

if [ -d "$STAGING/skills" ]; then
  rsync -a "$STAGING/skills/" "$DEST/skills/"
  echo "Synced skills/"
fi

if [ -f "$STAGING/CLAUDE.md" ]; then
  cp "$STAGING/CLAUDE.md" "$DEST/CLAUDE.md"
  echo "Synced CLAUDE.md"
fi

# Sync discord plugin server.ts override into the active plugin cache path.
# The install path is read from installed_plugins.json (may differ across versions).
DISCORD_SERVER="$STAGING/channels/discord/server.ts"
PLUGINS_JSON="$DEST/plugins/installed_plugins.json"
if [ -f "$DISCORD_SERVER" ] && [ -f "$PLUGINS_JSON" ]; then
  PLUGIN_PATH=$(python3 -c "
import json, sys
d = json.load(open('$PLUGINS_JSON'))
plugins = d.get('plugins', {})
for k, v in plugins.items():
    if 'discord' in k and '@claude-plugins-official' in k:
        entries = v if isinstance(v, list) else [v]
        for e in entries:
            p = e.get('installPath', '')
            if p:
                print(p)
                sys.exit(0)
" 2>/dev/null)
  if [ -n "$PLUGIN_PATH" ] && [ -d "$PLUGIN_PATH" ]; then
    cp "$DISCORD_SERVER" "$PLUGIN_PATH/server.ts"
    echo "Synced discord plugin server.ts -> $PLUGIN_PATH"
  else
    echo "Warning: could not determine discord plugin install path, skipping server.ts sync"
  fi

  # Also sync to the marketplaces path — Claude actually runs the plugin from here,
  # not from the installPath cache. Both need the inject endpoint.
  MARKETPLACES_PATH="$DEST/plugins/marketplaces/claude-plugins-official/external_plugins/discord"
  if [ -d "$MARKETPLACES_PATH" ]; then
    cp "$DISCORD_SERVER" "$MARKETPLACES_PATH/server.ts"
    echo "Synced discord plugin server.ts -> $MARKETPLACES_PATH"
  fi
fi

# Sync systemd user service files — keeps MemoryMax, resource limits, etc. in sync
SYSTEMD_STAGING="$STAGING/systemd/user"
SYSTEMD_DEST="$HOME/.config/systemd/user"
if [ -d "$SYSTEMD_STAGING" ]; then
  mkdir -p "$SYSTEMD_DEST"
  changed=0
  for f in "$SYSTEMD_STAGING"/*.service "$SYSTEMD_STAGING"/*.timer; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    dest_file="$SYSTEMD_DEST/$fname"
    if ! diff -q "$f" "$dest_file" > /dev/null 2>&1; then
      cp "$f" "$dest_file"
      echo "Synced systemd/$fname"
      changed=1
    fi
  done
  if [ "$changed" = "1" ]; then
    systemctl --user daemon-reload 2>/dev/null || true
    echo "systemd daemon-reload done"
  fi
fi
