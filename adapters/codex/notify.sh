#!/bin/bash
# Codex CLI adapter — capture at turn end via the `notify` hook.
# Codex runs this after each agent turn with the event JSON as the last argument:
#   {"type":"agent-turn-complete","turn-id":"…","input-messages":["…"],"last-assistant-message":"…","cwd":"…"}
# Codex has no per-tool hooks, so changed files are detected from git status and logged with mtime tracking.
# Retrieval and checkpoints happen through the MCP server (memory_context / memory_checkpoint); see README.md.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE="$DIR/scripts/memlog.sh"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PAYLOAD="${!#}"   # last argument
TYPE=$(printf '%s' "$PAYLOAD" | jq -r '.type // empty' 2>/dev/null)
[ "$TYPE" = "agent-turn-complete" ] || exit 0
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty'); [ -z "$CWD" ] && CWD="$PWD"

# 1) the user's request(s) for this turn
printf '%s' "$PAYLOAD" | jq -r '(.["input-messages"] // [])[]' | while IFS= read -r m; do
  [ -n "$m" ] && bash "$CORE" note "$CWD" "$m" >/dev/null 2>&1
done

# 2) files changed since the last turn: git status, filtered by mtime against a per-project state file
SLUG=$(printf '%s' "$CWD" | sed 's/[^A-Za-z0-9-]/-/g')
STATE="$CFG/projects/$SLUG/memory/log/.codex-mtimes"; mkdir -p "$(dirname "$STATE")"; touch "$STATE"
if git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$CWD" status --porcelain --untracked-files=all 2>/dev/null | cut -c4- | while IFS= read -r f; do
    [ -f "$CWD/$f" ] || continue
    mt=$(stat -f %m "$CWD/$f" 2>/dev/null || stat -c %Y "$CWD/$f" 2>/dev/null)
    old=$(grep -F -- "$f|" "$STATE" | tail -1 | cut -d'|' -f2)
    if [ "$mt" != "$old" ]; then
      bash "$CORE" edit "$CWD" "$CWD/$f" Edit >/dev/null 2>&1
      grep -vF -- "$f|" "$STATE" > "$STATE.tmp" 2>/dev/null; printf '%s|%s\n' "$f" "$mt" >> "$STATE.tmp"; mv "$STATE.tmp" "$STATE"
    fi
  done
fi

# 3) keep the index current
bash "$CORE" sync "$CWD" >/dev/null 2>&1
exit 0
