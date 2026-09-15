#!/bin/bash
# memlog.sh — local-memory plugin: capture + retrieval on top of Claude Code's built-in memory.
# Usage: memlog.sh prompt|tool|stop|start|search   (hook JSON arrives on stdin)
#   prompt : log the prompt, then inject the top matching past entries as context (RAG-at-prompt-time)
#   tool   : log file edits / state-changing commands, index them
#   stop   : every N changes ask the session to write a session-log entry; index new entries
#   start  : inject the last session entry so a new session picks up the thread
#   search : memlog.sh search "text" [limit]   (run from the project dir; no stdin)
# Markdown logs: ~/.claude/projects/<cwd-slug>/memory/log/YYYY-MM-DD.md
# Index:         ~/.claude-memory/index.db  (SQLite FTS5, no daemon)

MODE="$1"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDX="$DIR/memindex.py"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# isolated env with sqlite-vec + fastembed (vector search); falls back to plain python3 = BM25 only
PY="$HOME/.claude-memory/venv/bin/python"; [ -x "$PY" ] || PY=python3
python3() { "$PY" "$@"; }
# only hook modes receive JSON on stdin; CLI modes must not block on a terminal
case "$MODE" in prompt|tool|stop|start) INPUT=$(cat) ;; *) INPUT="" ;; esac
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD="$PWD"
SLUG=$(printf '%s' "$CWD" | sed 's/[^A-Za-z0-9-]/-/g')
MEM="$CFG/projects/$SLUG/memory"
LOG="$MEM/log"
TODAY=$(date +%F)
NOW=$(date +%H:%M)
DAYLOG="$LOG/$TODAY.md"
MARK="$LOG/.summary-mark"
SUMMARY_EVERY=${MEMLOG_SUMMARY_EVERY:-5}
RETRIEVE_N=${MEMLOG_RETRIEVE_N:-5}

ensure_index() {
  mkdir -p "$LOG"
  local idx="$MEM/MEMORY.md"
  [ -f "$idx" ] || printf '# Memory index\n\n' > "$idx"
  grep -q '](log/)' "$idx" 2>/dev/null || printf -- '- [Activity log](log/) — raw per-day log of prompts and file edits written by hooks; grep by date, filename or keyword\n' >> "$idx"
  grep -q '](session-log.md)' "$idx" 2>/dev/null || printf -- '- [Session log](session-log.md) — dated entries: request, learned, completed, next steps; newest at the bottom. Searchable with /memory-search\n' >> "$idx"
  grep -q '](observations.md)' "$idx" 2>/dev/null || printf -- '- [Observations](observations.md) — typed notes written at each checkpoint: discovery, change, feature, bugfix, decision, refactor; indexed for search\n' >> "$idx"
}

inject() {  # $1 = hook event name, $2 = context text
  jq -n --arg ev "$1" --arg ctx "$2" '{hookSpecificOutput:{hookEventName:$ev, additionalContext:$ctx}}'
}

case "$MODE" in
  prompt)
    P=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' | tr '\n' ' ' | cut -c1-400)
    [ -z "$P" ] && exit 0
    ensure_index
    printf '\n## %s prompt\n%s\n' "$NOW" "$P" >> "$DAYLOG"
    # retrieval: skip slash commands and very short prompts
    case "$P" in /*) exit 0 ;; esac
    [ "$(printf '%s' "$P" | wc -w)" -lt 3 ] && exit 0
    HITS=$(python3 "$IDX" query "$SLUG" "$P" "$RETRIEVE_N" 2>/dev/null | head -c 1800)
    [ -z "$HITS" ] && exit 0
    inject UserPromptSubmit "Relevant past memory for this project (from the local index; verify against the repo before relying on it):
$HITS"
    ;;
  tool)
    T=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
    case "$T" in
      Write|Edit|MultiEdit|NotebookEdit)
        F=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
        [ -z "$F" ] && exit 0
        F=${F#"$CWD"/}
        ensure_index
        printf -- '- %s %s %s\n' "$NOW" "$T" "$F" >> "$DAYLOG"
        python3 "$IDX" add "$SLUG" edit "$F" "$T $F" >/dev/null 2>&1
        ;;
      Bash)
        C=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' | tr '\n' ' ' | cut -c1-160)
        printf '%s' "$C" | grep -qE '^(git (commit|push|merge|rebase|checkout|switch|reset|tag)|npm |pnpm |yarn |bun |make|cargo |go |pip |uv |docker|kubectl|rm |mv |cp |mkdir|sed -i|python|node )' || exit 0
        ensure_index
        printf -- '- %s bash `%s`\n' "$NOW" "$C" >> "$DAYLOG"
        python3 "$IDX" add "$SLUG" command "$C" "" >/dev/null 2>&1
        ;;
      *) exit 0 ;;
    esac
    ;;
  stop)
    # index anything the session appended to session-log.md (cheap, deduplicated)
    [ -f "$MEM/session-log.md" ] && python3 "$IDX" sync "$SLUG" "$MEM/session-log.md" >/dev/null 2>&1
    # typed observations (discovery/change/feature/bugfix/decision/refactor) written at checkpoints
    [ -f "$MEM/observations.md" ] && python3 "$IDX" syncobs "$SLUG" "$MEM/observations.md" >/dev/null 2>&1
    # re-index hand-written memory files that changed (hash compare per file, cheap)
    python3 "$IDX" syncmd "$SLUG" "$MEM" >/dev/null 2>&1
    # embed any rows added since the last stop (model loads once, ~0.4s; skipped when nothing is pending)
    python3 "$IDX" embed 500 >/dev/null 2>&1
    ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')
    [ "$ACTIVE" = "true" ] && exit 0
    [ -f "$DAYLOG" ] || exit 0
    EDITS=$(grep -c '^- ' "$DAYLOG" 2>/dev/null); EDITS=${EDITS:-0}
    LAST=0; [ -f "$MARK" ] && LAST=$(cat "$MARK")
    MARKDAY=""; [ -f "$MARK.day" ] && MARKDAY=$(cat "$MARK.day")
    [ "$MARKDAY" != "$TODAY" ] && LAST=0
    if [ $((EDITS - LAST)) -ge "$SUMMARY_EVERY" ]; then
      printf '%s' "$EDITS" > "$MARK"; printf '%s' "$TODAY" > "$MARK.day"
      ensure_index
      # what changed in this window: the '- ' lines after the previous checkpoint, split into files and commands
      WINDOW=$(grep '^- ' "$DAYLOG" | sed -n "$((LAST + 1)),${EDITS}p")
      FILES=$(printf '%s\n' "$WINDOW" | grep -vE '^- [0-9:]+ bash ' | awk '{ $1=""; $2=""; $3=""; sub(/^ +/, ""); print }' | awk '!seen[$0]++' | paste -sd '\n' - | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/, /g')
      CMDS=$(printf '%s\n' "$WINDOW" | grep -E '^- [0-9:]+ bash ' | sed -E 's/^- [0-9:]+ bash //' | awk '!seen[$0]++' | head -8 | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/; /g')
      NFILES=$(printf '%s' "$FILES" | awk -F', ' '{print ($0=="")?0:NF}')
      # mark the window boundary in the day log (### lines are not counted as changes)
      printf '\n### checkpoint %s — %s change(s): %s\n\n' "$NOW" "$((EDITS - LAST))" "${FILES:-commands only}" >> "$DAYLOG"
      REASON="Memory checkpoint: $((EDITS - LAST)) changes since the last one, touching $NFILES file(s). Do two small writes, then stop (do not repeat the work).

Files changed in this window: ${FILES:-none}
Commands run: ${CMDS:-none}

1) Append ONE entry to $MEM/session-log.md (create it with a '# Session log' header if missing):

## $TODAY $NOW — <one-line request>
**Files:** ${FILES:-none}
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

If any fact is durable (a decision, a convention, a user preference), also save it as its own memory file and add it to $MEM/MEMORY.md."
      jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
    fi
    ;;
  start)
    # record slug -> real path once per session so the project can be found after its folder is deleted
    python3 "$IDX" touch "$SLUG" "$CWD" >/dev/null 2>&1
    L=$(python3 "$IDX" last "$SLUG" 2>/dev/null | head -c 1500)
    HINT=""
    if [ ! -x "$HOME/.claude-memory/venv/bin/python" ] && [ ! -f "$HOME/.claude-memory/.setup-hint-shown" ]; then
      mkdir -p "$HOME/.claude-memory"; touch "$HOME/.claude-memory/.setup-hint-shown"
      HINT="local-memory: keyword search is active; semantic (vector) search is off until you run: bash $DIR/setup.sh"
    fi
    [ -z "$L" ] && [ -z "$HINT" ] && exit 0
    inject SessionStart "${HINT:+$HINT
}${L:+Where this project was left (latest session entry from the memory index):
$L}"
    ;;
  search)
    python3 "$IDX" query "$SLUG" "$2" "${3:-10}"
    ;;
  forget)   # memlog.sh forget /path/to/project [--files]   — drop a project from the index (and its memory folder with --files)
    python3 "$IDX" forget "$2" $3
    ;;
  projects) # memlog.sh projects   — list indexed projects and whether their folder still exists
    python3 "$IDX" projects
    ;;
  prune)    # memlog.sh prune [--apply] [--files]   — forget every project whose folder is gone
    python3 "$IDX" prune $2 $3
    ;;
  ui)       # memlog.sh ui [port]   — open the memory viewer in the browser; Ctrl-C stops it
    exec "$PY" "$DIR/memview.py" "${2:-37701}"
    ;;
esac
exit 0
