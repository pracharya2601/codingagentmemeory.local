#!/bin/bash
# Cursor hooks adapter — translates Cursor hook events (JSON on stdin) into local-memory core calls.
# Usage (from ~/.cursor/hooks.json or <project>/.cursor/hooks.json):
#   bash /path/to/adapters/cursor/cursor-hook.sh <event>
# Events handled: beforeSubmitPrompt, afterFileEdit, afterShellExecution, stop
# Retrieval into the prompt is not possible from Cursor hooks; use the MCP server + local-memory.mdc rule for that.
EVENT="$1"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE="$DIR/scripts/memlog.sh"
INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '(.workspace_roots // [])[0] // .cwd // empty')
[ -z "$CWD" ] && CWD="$PWD"

case "$EVENT" in
  beforeSubmitPrompt)
    P=$(printf '%s' "$INPUT" | jq -r '.prompt // empty')
    [ -n "$P" ] && bash "$CORE" note "$CWD" "$P" >/dev/null 2>&1
    echo '{"continue": true}'
    ;;
  afterFileEdit)
    F=$(printf '%s' "$INPUT" | jq -r '.file_path // empty')
    [ -n "$F" ] && bash "$CORE" edit "$CWD" "$F" Edit >/dev/null 2>&1
    ;;
  afterShellExecution)
    C=$(printf '%s' "$INPUT" | jq -r '.command // empty')
    [ -n "$C" ] && bash "$CORE" cmd "$CWD" "$C" >/dev/null 2>&1
    ;;
  stop)
    # Cursor's stop hook may return followup_message, which is sent to the agent as the next user turn.
    R=$(bash "$CORE" due "$CWD" 2>/dev/null)
    if [ -n "$R" ]; then jq -n --arg m "$R" '{followup_message: $m}'; fi
    ;;
esac
exit 0
