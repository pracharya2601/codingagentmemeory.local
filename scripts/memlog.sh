#!/bin/bash
# memlog.sh — local-memory core: capture, checkpoints and retrieval on top of per-project Markdown memory
# plus a SQLite index (memindex.py). Tool-neutral; adapters translate each agent's events into these calls.
#
# Claude Code hook modes (JSON on stdin):     start | prompt | tool | stop
# Core modes (arguments, usable from any tool):
#   note     <cwd> <text>                log a user prompt
#   edit     <cwd> <path> [tool]         log a file write/edit
#   cmd      <cwd> <command>             log a state-changing shell command (read-only commands are skipped)
#   retrieve <cwd> <text> [n]            print the top-n matching past entries (plain text; empty if none)
#   last     <cwd>                       print the latest session entry (where the project was left)
#   sync     <cwd>                       index session-log.md / observations.md / memory files, embed pending rows
#   due      <cwd>                       if a checkpoint is due, print the checkpoint instructions and arm it
#   search   <text> [n]                  search from the current directory
#   projects | forget <path> [--files] | prune [--apply] [--files] | ui [port]
#
# Layout:  <config>/projects/<slug>/memory/{MEMORY.md,session-log.md,observations.md,log/YYYY-MM-DD.md}
#          ~/.claude-memory/index.db  (SQLite FTS5 + optional sqlite-vec)

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDX="$DIR/memindex.py"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PY="$HOME/.claude-memory/venv/bin/python"; [ -x "$PY" ] || PY=python3
python3() { "$PY" "$@"; }

SUMMARY_EVERY=${MEMLOG_SUMMARY_EVERY:-5}
RETRIEVE_N=${MEMLOG_RETRIEVE_N:-5}
# How Claude Code receives a due checkpoint:
#   quiet (default) — stored at stop, delivered silently as context on the next prompt (nothing printed in the terminal)
#   block           — the Stop hook holds the agent for one more turn; Claude Code prints the request as a "hook error"
CHECKPOINT_MODE=${MEMLOG_CHECKPOINT_MODE:-quiet}
MODE="$1"

# ---------- project context ----------
set_project() {  # $1 = cwd
  CWD="${1:-$PWD}"
  SLUG=$(printf '%s' "$CWD" | sed 's/[^A-Za-z0-9-]/-/g')
  MEM="$CFG/projects/$SLUG/memory"
  LOG="$MEM/log"
  TODAY=$(date +%F); NOW=$(date +%H:%M)
  DAYLOG="$LOG/$TODAY.md"
  MARK="$LOG/.summary-mark"
  PENDING="$MEM/.checkpoint-pending.md"
}

# Print and clear a stored checkpoint request, if any.
take_pending() {
  [ -f "$PENDING" ] || return 0
  cat "$PENDING"; rm -f "$PENDING"
}

ensure_index() {
  mkdir -p "$LOG"
  local idx="$MEM/MEMORY.md"
  [ -f "$idx" ] || printf '# Memory index\n\n' > "$idx"
  grep -q '](log/)' "$idx" 2>/dev/null || printf -- '- [Activity log](log/) — raw per-day log of prompts and file edits written by hooks; grep by date, filename or keyword\n' >> "$idx"
  grep -q '](session-log.md)' "$idx" 2>/dev/null || printf -- '- [Session log](session-log.md) — dated checkpoints: request, files, learned, completed, next steps; newest at the bottom\n' >> "$idx"
  grep -q '](observations.md)' "$idx" 2>/dev/null || printf -- '- [Observations](observations.md) — typed notes written at each checkpoint: discovery, change, feature, bugfix, decision, refactor; indexed for search\n' >> "$idx"
}

# ---------- core operations ----------
log_prompt() {  # $1 = text
  local p; p=$(printf '%s' "$1" | tr '\n' ' ' | cut -c1-400)
  [ -z "$p" ] && return 1
  ensure_index
  printf '\n## %s prompt\n%s\n' "$NOW" "$p" >> "$DAYLOG"
}

log_edit() {  # $1 = path, $2 = tool name
  local f="$1" t="${2:-Edit}"
  [ -z "$f" ] && return 1
  f=${f#"$CWD"/}
  ensure_index
  printf -- '- %s %s %s\n' "$NOW" "$t" "$f" >> "$DAYLOG"
  python3 "$IDX" add "$SLUG" edit "$f" "$t $f" >/dev/null 2>&1
}

log_cmd() {  # $1 = command
  local c; c=$(printf '%s' "$1" | tr '\n' ' ' | cut -c1-160)
  printf '%s' "$c" | grep -qE '^(git (commit|push|merge|rebase|checkout|switch|reset|tag)|npm |pnpm |yarn |bun |make|cargo |go |pip |uv |docker|kubectl|rm |mv |cp |mkdir|sed -i|python|node )' || return 0
  ensure_index
  printf -- '- %s bash `%s`\n' "$NOW" "$c" >> "$DAYLOG"
  python3 "$IDX" add "$SLUG" command "$c" "" >/dev/null 2>&1
}

retrieve() {  # $1 = text, $2 = n  -> stdout
  local t="$1" n="${2:-$RETRIEVE_N}"
  case "$t" in /*) return 0 ;; esac
  [ "$(printf '%s' "$t" | wc -w)" -lt 3 ] && return 0
  python3 "$IDX" query "$SLUG" "$t" "$n" 2>/dev/null | head -c 1800
}

last_entry() { python3 "$IDX" last "$SLUG" 2>/dev/null | head -c 1500; }

sync_all() {
  [ -f "$MEM/session-log.md" ] && python3 "$IDX" sync "$SLUG" "$MEM/session-log.md" >/dev/null 2>&1
  [ -f "$MEM/observations.md" ] && python3 "$IDX" syncobs "$SLUG" "$MEM/observations.md" >/dev/null 2>&1
  python3 "$IDX" syncmd "$SLUG" "$MEM" >/dev/null 2>&1
  python3 "$IDX" embed 500 >/dev/null 2>&1
}

# Prints the checkpoint instructions if enough changes accumulated since the last one, and arms the marker.
# Prints nothing otherwise.
checkpoint_if_due() {
  [ -f "$DAYLOG" ] || return 0
  local edits last markday window files cmds nfiles
  edits=$(grep -c '^- ' "$DAYLOG" 2>/dev/null); edits=${edits:-0}
  last=0; [ -f "$MARK" ] && last=$(cat "$MARK")
  markday=""; [ -f "$MARK.day" ] && markday=$(cat "$MARK.day")
  [ "$markday" != "$TODAY" ] && last=0
  [ $((edits - last)) -ge "$SUMMARY_EVERY" ] || return 0
  printf '%s' "$edits" > "$MARK"; printf '%s' "$TODAY" > "$MARK.day"
  ensure_index
  window=$(grep '^- ' "$DAYLOG" | sed -n "$((last + 1)),${edits}p")
  # joins are done in awk: BSD sed's N drops a single trailing line, GNU sed does not
  files=$(printf '%s\n' "$window" | grep -vE '^- [0-9:]+ bash ' | awk '{ $1=""; $2=""; $3=""; sub(/^ +/, ""); print }' | awk '!seen[$0]++' | awk '{ printf "%s%s", (NR>1 ? ", " : ""), $0 }')
  cmds=$(printf '%s\n' "$window" | grep -E '^- [0-9:]+ bash ' | sed -E 's/^- [0-9:]+ bash //' | awk '!seen[$0]++' | head -8 | awk '{ printf "%s%s", (NR>1 ? "; " : ""), $0 }')
  nfiles=$(printf '%s' "$files" | awk -F', ' '{print ($0=="")?0:NF}')
  printf '\n### checkpoint %s — %s change(s): %s\n\n' "$NOW" "$((edits - last))" "${files:-commands only}" >> "$DAYLOG"
  # printed for immediate delivery AND stored for deferred delivery (quiet mode / next session)
  { cat <<EOF
Memory checkpoint: $((edits - last)) changes since the last one, touching $nfiles file(s). Do two small writes first (do not repeat the work).

Files changed in this window: ${files:-none}
Commands run: ${cmds:-none}

1) Append ONE entry to $MEM/session-log.md (create it with a '# Session log' header if missing):

## $TODAY $NOW — <one-line request>
**Files:** ${files:-none}
**Learned:** <non-obvious facts, gotchas, measurements>
**Completed:** <what changed, per file above>
**Next steps:** <pending work, blockers, open decisions>

Copy the Files line verbatim. Under 150 words after it.

2) Append a block to $MEM/observations.md (create it with a '# Observations' header if missing) with 1-6 typed observations covering ONLY what happened since the last checkpoint, one per line, most important first:

## $TODAY $NOW
- [discovery] <title> — <facts: what was found, where, numbers>
- [change] <title> — <what changed and why, files>
- [feature] <title> — <capability added, how to use it>
- [bugfix] <title> — <symptom, cause, fix>
- [decision] <title> — <what was decided, alternatives rejected, why>
- [refactor] <title> — <what moved/simplified, no behaviour change>

Use only the types that apply; skip trivial edits. Each line under 60 words and must name the file(s) it concerns from the list above. Titles must stand alone when read months later.

If any fact is durable (a decision, a convention, a user preference), also save it as its own memory file and add it to $MEM/MEMORY.md.
EOF
  } | tee "$PENDING"
}

setup_hint() {
  if [ ! -x "$HOME/.claude-memory/venv/bin/python" ] && [ ! -f "$HOME/.claude-memory/.setup-hint-shown" ]; then
    mkdir -p "$HOME/.claude-memory"; touch "$HOME/.claude-memory/.setup-hint-shown"
    printf 'local-memory: keyword search is active; semantic (vector) search is off until you run: bash %s/setup.sh\n' "$DIR"
  fi
}

inject() {  # Claude Code hook output: $1 = event, $2 = context
  jq -n --arg ev "$1" --arg ctx "$2" '{hookSpecificOutput:{hookEventName:$ev, additionalContext:$ctx}}'
}

# ---------- Claude Code hook modes (JSON on stdin) ----------
case "$MODE" in
  start|prompt|tool|stop)
    INPUT=$(cat)
    set_project "$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
    ;;
esac

case "$MODE" in
  start)
    python3 "$IDX" touch "$SLUG" "$CWD" >/dev/null 2>&1
    L=$(last_entry); HINT=$(setup_hint); PEND=$(take_pending)
    [ -z "$L" ] && [ -z "$HINT" ] && [ -z "$PEND" ] && exit 0
    inject SessionStart "${HINT:+$HINT
}${PEND:+A memory checkpoint from the previous session was never written. Reconstruct it from the day log in $LOG and the repository, then continue:
$PEND

}${L:+Where this project was left (latest session entry from the memory index):
$L}"
    ;;
  prompt)
    P=$(printf '%s' "$INPUT" | jq -r '.prompt // empty')
    log_prompt "$P" || exit 0
    HITS=$(retrieve "$P"); PEND=$(take_pending)
    [ -z "$HITS" ] && [ -z "$PEND" ] && exit 0
    inject UserPromptSubmit "${PEND:+Before handling the request below, do this pending memory checkpoint (it covers your earlier work in this project); then continue with the request:
$PEND

}${HITS:+Relevant past memory for this project (from the local index; verify against the repo before relying on it):
$HITS}"
    ;;
  tool)
    T=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
    case "$T" in
      Write|Edit|MultiEdit|NotebookEdit) log_edit "$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')" "$T" ;;
      Bash) log_cmd "$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')" ;;
    esac
    ;;
  stop)
    sync_all
    if [ "$CHECKPOINT_MODE" = "block" ]; then
      [ "$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0
      R=$(checkpoint_if_due); [ -z "$R" ] && exit 0
      rm -f "$PENDING"                       # delivered now, not later
      jq -n --arg r "$R" '{decision:"block", reason:$r}'
    else
      checkpoint_if_due >/dev/null           # quiet: stored in $PENDING, delivered on the next prompt
    fi
    ;;

  # ---------- core modes (arguments) ----------
  note)     set_project "$2"; log_prompt "$3" ;;
  edit)     set_project "$2"; log_edit "$3" "${4:-Edit}" ;;
  cmd)      set_project "$2"; log_cmd "$3" ;;
  retrieve) set_project "$2"; retrieve "$3" "${4:-$RETRIEVE_N}" ;;
  last)     set_project "$2"; python3 "$IDX" touch "$SLUG" "$CWD" >/dev/null 2>&1; last_entry ;;
  sync)     set_project "$2"; sync_all ;;
  due)      set_project "$2"; sync_all
            R=$(checkpoint_if_due)
            if [ -n "$R" ]; then printf '%s\n' "$R"; rm -f "$PENDING"; else take_pending; fi ;;   # caller delivers it

  # ---------- CLI ----------
  search)   set_project "$PWD"; python3 "$IDX" query "$SLUG" "$2" "${3:-10}" ;;
  forget)   python3 "$IDX" forget "$2" $3 ;;
  projects) python3 "$IDX" projects ;;
  prune)    python3 "$IDX" prune $2 $3 ;;
  ui)       exec "$PY" "$DIR/memview.py" "${2:-37701}" ${3:+"$3"} ;;   # ui [port] [name,name]
  *)        sed -n '2,16p' "$0"; exit 1 ;;
esac
exit 0
