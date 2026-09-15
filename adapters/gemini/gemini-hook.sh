#!/bin/bash
# Gemini CLI hooks adapter — translates Gemini CLI hook events (JSON on stdin) into local-memory core calls.
# Usage (from ~/.gemini/settings.json "hooks"):
#   bash /path/to/adapters/gemini/gemini-hook.sh <SessionStart|BeforeAgent|AfterTool|AfterAgent>
# Output follows the Gemini CLI hook contract: hookSpecificOutput.additionalContext to add context,
# decision/reason on AfterAgent to hold the agent for a checkpoint.
EVENT="$1"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE="$DIR/scripts/memlog.sh"
INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty'); [ -z "$CWD" ] && CWD="$PWD"

inject() { jq -n --arg ev "$EVENT" --arg ctx "$1" '{hookSpecificOutput:{hookEventName:$ev, additionalContext:$ctx}}'; }

case "$EVENT" in
  SessionStart)
    L=$(bash "$CORE" last "$CWD" 2>/dev/null)
    [ -n "$L" ] && inject "Where this project was left (latest checkpoint from local memory):
$L"
    ;;
  BeforeAgent)
    P=$(printf '%s' "$INPUT" | jq -r '.prompt // .user_prompt // empty')
    [ -z "$P" ] && exit 0
    bash "$CORE" note "$CWD" "$P" >/dev/null 2>&1
    H=$(bash "$CORE" retrieve "$CWD" "$P" 2>/dev/null)
    [ -n "$H" ] && inject "Relevant past memory for this project (verify against the repo before relying on it):
$H"
    ;;
  AfterTool)
    T=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
    case "$T" in
      write_file|replace|edit|write|create_file)
        F=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.absolute_path // empty')
        [ -n "$F" ] && bash "$CORE" edit "$CWD" "$F" "$T" >/dev/null 2>&1 ;;
      run_shell_command|shell|bash)
        C=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
        [ -n "$C" ] && bash "$CORE" cmd "$CWD" "$C" >/dev/null 2>&1 ;;
    esac
    ;;
  AfterAgent)
    [ "$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0
    R=$(bash "$CORE" due "$CWD" 2>/dev/null)
    [ -n "$R" ] && jq -n --arg r "$R" '{decision:"block", reason:$r}'
    ;;
esac
exit 0
