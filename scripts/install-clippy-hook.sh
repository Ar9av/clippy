#!/bin/zsh
# Registers the session-handoff hook with Claude Code, so a finished session
# shows up in Clippy with a summary and a way to resume it.
#
# Merges into ~/.claude/settings.json rather than overwriting: that file
# usually already has hooks in it, and clobbering someone's configuration to
# install a convenience would be a poor trade.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
HOOK="$SCRIPT_DIR/clippy-session-handoff.sh"
SETTINGS="$HOME/.claude/settings.json"

chmod +x "$HOOK"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.clippy-backup"

/usr/bin/python3 - "$SETTINGS" "$HOOK" <<'PY'
import json, sys

settings_path, hook_path = sys.argv[1], sys.argv[2]
with open(settings_path) as handle:
    try:
        settings = json.load(handle)
    except Exception:
        settings = {}

hooks = settings.setdefault("hooks", {})
entries = hooks.setdefault("SessionEnd", [])

# Idempotent: re-running must not stack duplicate hooks that all fire.
def already_installed(entries):
    for entry in entries:
        for hook in entry.get("hooks", []):
            if hook_path in (hook.get("command") or ""):
                return True
    return False

if not already_installed(entries):
    entries.append({
        "matcher": "",
        "hooks": [{"type": "command", "command": hook_path}],
    })

with open(settings_path, "w") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
print("SessionEnd hook installed" if not already_installed([]) else "")
PY

echo "Installed. Backup of previous settings: $SETTINGS.clippy-backup"
