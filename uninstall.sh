#!/bin/bash
# ClaudeBar uninstaller: removes the app, its hooks from
# ~/.claude/settings.json (leaving every other hook alone), and ~/.claudebar.
set -euo pipefail

APP="$HOME/Applications/ClaudeBar.app"
CLAUDEBAR_DIR="$HOME/.claudebar"
SETTINGS="$HOME/.claude/settings.json"

pkill -x ClaudeBar 2>/dev/null || true

if [ -f "$SETTINGS" ]; then
  echo "Removing ClaudeBar hooks from $SETTINGS"
  python3 - "$SETTINGS" "$CLAUDEBAR_DIR/claudebar-relay.sh" <<'PYEOF'
import json, os, shutil, sys, tempfile

settings_path, relay = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f:
        settings = json.load(f)
except ValueError as e:
    sys.exit(f"  {settings_path} isn't valid JSON ({e}); remove the claudebar-relay.sh hooks by hand.")

hooks = settings.get("hooks", {})
removed = 0
for event in list(hooks):
    kept_entries = []
    for entry in hooks[event]:
        inner = entry.get("hooks", [])
        kept = [h for h in inner if h.get("command") != relay]
        removed += len(inner) - len(kept)
        if kept:
            kept_entries.append({**entry, "hooks": kept})
        elif not inner:
            kept_entries.append(entry)  # not ours; leave it be
    if kept_entries:
        hooks[event] = kept_entries
    else:
        del hooks[event]
if "hooks" in settings and not hooks:
    del settings["hooks"]

if removed:
    shutil.copy2(settings_path, settings_path + ".claudebar-backup")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(settings_path), prefix=".settings-")
    with os.fdopen(fd, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp, settings_path)
print(f"  removed {removed} hook(s)")
PYEOF
fi

echo "Removing $APP and $CLAUDEBAR_DIR"
rm -rf "$APP" "$CLAUDEBAR_DIR"
echo "ClaudeBar is gone. Your Touch Bar is yours again."
