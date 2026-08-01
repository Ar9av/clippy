#!/bin/zsh
# Claude Code SessionEnd hook: hands a finished session to Clippy.
#
# Claude Code passes a JSON object on stdin carrying at least session_id, cwd,
# and transcript_path. This writes a small handoff file into the directory
# Clippy watches; Clippy shows a one-line summary and offers to resume.
#
# Install with:  ./scripts/install-clippy-hook.sh
#
# Deliberately silent and always exit 0: a hook that fails, prints, or blocks
# would interfere with the session it is reporting on, and a missed summary is
# not worth that.

set -u

# Clippy drives these CLIs itself, and every one of those is a session that
# ends. Reporting them back would announce Clippy's own queries as finished
# work; the variable is set by whatever Clippy spawns and inherited here.
[ -n "${CLIPPY_INTERNAL:-}" ] && exit 0

INBOX="$HOME/Library/Application Support/Clippy/SessionHandoffs"
mkdir -p "$INBOX" 2>/dev/null || exit 0

payload="$(cat 2>/dev/null)" || exit 0
[ -n "$payload" ] || exit 0

# The interpreter reads its program from a variable and the event from stdin;
# feeding both through redirects collides, since only the last one applies.
read -r -d '' HANDOFF_PY <<'PY'

import json, os, sys, datetime, re

inbox = sys.argv[1]
try:
    event = json.load(sys.stdin)
except Exception:
    sys.exit(0)

session_id = event.get("session_id") or ""
if not session_id:
    sys.exit(0)
cwd = event.get("cwd") or os.getcwd()

def summarise(path):
    """Last thing the assistant actually said, condensed to a line or two.

    Read from the tail rather than parsed whole: a long session's transcript
    is large, and only the end is relevant to "what just happened".
    """
    if not path or not os.path.exists(path):
        return ""
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - 200_000))
            lines = handle.read().decode("utf-8", "replace").splitlines()
    except Exception:
        return ""

    for line in reversed(lines):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            entry = json.loads(line)
        except Exception:
            continue
        message = entry.get("message") or {}
        if entry.get("type") != "assistant" and message.get("role") != "assistant":
            continue
        content = message.get("content")
        text = ""
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            text = " ".join(
                block.get("text", "")
                for block in content
                if isinstance(block, dict) and block.get("type") == "text"
            )
        text = re.sub(r"\s+", " ", text).strip()
        if text:
            return text[:400]
    return ""

handoff = {
    "id": session_id,
    "provider": "claude",
    "projectPath": cwd,
    "summary": summarise(event.get("transcript_path")),
    "endedAt": datetime.datetime.now(datetime.timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
}

target = os.path.join(inbox, session_id + ".json")
# Write then rename, so Clippy never reads a half-written file.
temporary = target + ".partial"
with open(temporary, "w") as handle:
    json.dump(handoff, handle, indent=2, sort_keys=True)
os.replace(temporary, target)
PY

printf '%s' "$payload" | /usr/bin/python3 -c "$HANDOFF_PY" "$INBOX" 2>/dev/null

exit 0
