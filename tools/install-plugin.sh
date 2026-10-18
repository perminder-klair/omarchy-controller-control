#!/usr/bin/env bash
# Install (or re-install) this working tree as an Omarchy shell plugin.
#
# Omarchy refuses symlinks inside a plugin folder, so a checkout cannot simply
# be linked into place -- it has to be copied. This mirrors what
# `omarchy plugin add <git-url>` would drop there, minus the VCS metadata.
set -euo pipefail

id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' \
      "$(dirname "$0")/../manifest.json")"
src="$(cd "$(dirname "$0")/.." && pwd)"
# The shell looks in $HOME/.config whatever XDG_CONFIG_HOME says.
dest="$HOME/.config/omarchy/plugins/$id"

if [ -L "$dest" ]; then
  rm -f "$dest"
fi

# The service is keepLoaded, so a rescan keeps the old instance running.
# Note whether it changed, to say so afterwards.
service_changed=false
if [ -f "$dest/Service.qml" ] && ! cmp -s "$src/Service.qml" "$dest/Service.qml"; then
  service_changed=true
fi

mkdir -p "$dest"
rsync -a --delete \
  --exclude '.git/' \
  --exclude '.gitignore' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  --exclude '.venv/' \
  "$src/" "$dest/"

omarchy plugin validate "$dest"
echo "installed $id -> $dest"

if ! omarchy plugin list --json 2>/dev/null |
    python3 -c 'import json,sys; sys.exit(not any(p["id"] == sys.argv[1] and p["enabled"] for p in json.load(sys.stdin)))' "$id"; then
  echo "note: enable it with 'omarchy plugin enable $id'"
fi

# Pick up the new panel and widget without restarting the whole shell, and
# restart the daemon so it runs the new engine.
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
omarchy-shell controller restart >/dev/null 2>&1 || true
echo "shell rescanned, daemon restarted"

if $service_changed; then
  echo "note: Service.qml changed; restart the shell (or disable and re-enable $id) to load it"
fi
