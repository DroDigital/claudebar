#!/bin/bash
# ClaudeBar installer:
#   1. copies the app to ~/Applications
#   2. copies the hook relay script to ~/.claudebar
#   3. registers the relay in ~/.claude/settings.json (merged, never clobbered)
#   4. writes a starter config if you don't have one
# Safe to re-run: it upgrades in place and never duplicates hooks.
set -euo pipefail
cd "$(dirname "$0")"

APP_SRC="build/ClaudeBar.app"
APP_DEST="$HOME/Applications/ClaudeBar.app"
CLAUDEBAR_DIR="$HOME/.claudebar"
SETTINGS="$HOME/.claude/settings.json"

if [ ! -d "$APP_SRC" ]; then
  echo "No build found — run 'make' first." >&2
  exit 1
fi

echo "Installing app to $APP_DEST"
mkdir -p "$HOME/Applications" "$CLAUDEBAR_DIR" "$HOME/.claude"
pkill -x ClaudeBar 2>/dev/null && sleep 1 || true
rm -rf "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"

echo "Installing hook relay to $CLAUDEBAR_DIR"
cp hooks/claudebar-relay.sh "$CLAUDEBAR_DIR/"
chmod +x "$CLAUDEBAR_DIR/claudebar-relay.sh"

if [ ! -f "$CLAUDEBAR_DIR/config.json" ]; then
  echo "Writing starter config to $CLAUDEBAR_DIR/config.json"
  cat > "$CLAUDEBAR_DIR/config.json" <<'EOF'
{
  "skills": ["/code-review", "/simplify", "/init"],
  "showUsage": true,
  "offerSkipPermissions": true
}
EOF
fi

echo "Registering Claude Code hooks in $SETTINGS"
python3 - "$SETTINGS" "$CLAUDEBAR_DIR/claudebar-relay.sh" <<'PYEOF'
import json, os, shutil, sys, tempfile

settings_path, relay = sys.argv[1], sys.argv[2]
settings = {}
if os.path.exists(settings_path):
    try:
        with open(settings_path) as f:
            settings = json.load(f)
    except ValueError as e:
        sys.exit(f"  {settings_path} isn't valid JSON ({e}); fix it and re-run.")
    shutil.copy2(settings_path, settings_path + ".claudebar-backup")

hooks = settings.setdefault("hooks", {})
relay_hook = {"type": "command", "command": relay}

# PostToolUse lets ClaudeBar notice a permission prompt you answered at
# the keyboard, so it never shows buttons for a prompt that's gone.
for event in ["SessionStart", "SessionEnd", "Notification", "Stop",
              "UserPromptSubmit", "PostToolUse"]:
    entries = hooks.setdefault(event, [])
    already = any(
        h.get("command") == relay
        for entry in entries
        for h in entry.get("hooks", [])
    )
    if not already:
        entries.append({"hooks": [relay_hook]})

# Write atomically: a crash mid-write must never leave a truncated file.
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(settings_path), prefix=".settings-")
with os.fdopen(fd, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
os.replace(tmp, settings_path)
print("  hooks registered")
PYEOF

echo
echo "Done! Launching ClaudeBar…"
open "$APP_DEST"
echo
echo "First-run checklist:"
echo "  • macOS will ask for Accessibility access (needed to press keys"
echo "    in your terminal) — approve it in System Settings."
echo "  • Start a 'claude' session in your terminal; the Touch Bar"
echo "    switches to Claude mode automatically."
echo "  • Already-running sessions are picked up on their next event."
echo
echo "To remove ClaudeBar later: make uninstall"
