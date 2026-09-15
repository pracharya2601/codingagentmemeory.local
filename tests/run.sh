#!/bin/bash
# tests/run.sh — offline test suite. Uses a throwaway project and a throwaway index; nothing of yours is touched.
# Requires: bash, jq, python3 (sqlite with FTS5), node (for the OpenCode syntax check; skipped if absent).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; export MEMINDEX_DB="$TMP/index.db" MEMINDEX_NOVEC=1 CLAUDE_CONFIG_DIR="$TMP/config"
T="$TMP/project"; mkdir -p "$T" "$CLAUDE_CONFIG_DIR/projects"
H="$ROOT/scripts/memlog.sh"; PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else fail "$1"; fi; }

echo "core"
bash "$H" note "$T" "add rate limiting to the api gateway" >/dev/null
bash "$H" edit "$T" "$T/src/gateway/ratelimit.go" >/dev/null
bash "$H" edit "$T" "$T/src/gateway/config.go" Write >/dev/null
bash "$H" cmd "$T" "ls -la" >/dev/null
bash "$H" cmd "$T" "go test ./..." >/dev/null
check "read-only command skipped"           '[ "$(grep -c "ls -la" "$CLAUDE_CONFIG_DIR"/projects/*/memory/log/*.md)" = 0 ]'
check "state-changing command logged"       'grep -q "go test" "$CLAUDE_CONFIG_DIR"/projects/*/memory/log/*.md'
check "no checkpoint below threshold"       '[ -z "$(bash "$H" due "$T")" ]'
bash "$H" edit "$T" "$T/a.go" >/dev/null; bash "$H" edit "$T" "$T/b.go" >/dev/null
DUE=$(bash "$H" due "$T")
check "checkpoint fires at 5 changes"       '[ -n "$DUE" ]'
check "checkpoint lists window files"       'printf "%s" "$DUE" | grep -q "src/gateway/ratelimit.go, src/gateway/config.go, a.go, b.go"'
check "checkpoint lists commands"           'printf "%s" "$DUE" | grep -q "go test"'
check "checkpoint armed (no repeat)"        '[ -z "$(bash "$H" due "$T")" ]'
check "day log has boundary marker"         'grep -q "^### checkpoint" "$CLAUDE_CONFIG_DIR"/projects/*/memory/log/*.md'
check "retrieve finds edit by filename"     'bash "$H" retrieve "$T" "what happened with the ratelimit file" 3 | grep -q ratelimit.go'
check "retrieve empty for short prompt"     '[ -z "$(bash "$H" retrieve "$T" "ok thanks")" ]'
M="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$T" | sed 's/[^A-Za-z0-9-]/-/g')/memory"
printf '# Session log\n\n## 2026-01-02 10:00 — wire limiter\n**Files:** a.go\n**Learned:** token bucket\n**Completed:** limiter\n**Next steps:** config\n' > "$M/session-log.md"
printf '# Observations\n\n## 2026-01-02 10:00\n- [decision] Per client id not per IP — NAT shares IPs\n- [bugfix] Off by one in bucket refill — a.go\n' > "$M/observations.md"
bash "$H" sync "$T"
check "session entry indexed and returned by last" 'bash "$H" last "$T" | grep -q "wire limiter"'
check "observation typed as decision"       'bash "$H" retrieve "$T" "why per client id instead of ip" 2 | grep -q "\[2026-01-02 decision\]"'
bash "$H" sync "$T"
N=$(python3 "$ROOT/scripts/memindex.py" stats | grep -c decision)
check "re-sync is idempotent"               '[ "$N" = 1 ]'

echo "claude code hook modes"
check "tool hook logs edit"                 'jq -nc --arg c "$T" "{cwd:\$c, tool_name:\"Edit\", tool_input:{file_path:(\$c+\"/z.go\")}}" | bash "$H" tool; grep -q "Edit z.go" "$M"/log/*.md'
check "prompt hook injects context"         'jq -nc --arg c "$T" "{cwd:\$c, prompt:\"tell me about the rate limiter decision\"}" | bash "$H" prompt | jq -e ".hookSpecificOutput.additionalContext" >/dev/null'
check "start hook injects last entry"       'jq -nc --arg c "$T" "{cwd:\$c}" | bash "$H" start | jq -r ".hookSpecificOutput.additionalContext" | grep -q "wire limiter"'
STOP_OUT=$(jq -nc --arg c "$T" '{cwd:$c, stop_hook_active:false}' | bash "$H" stop)
check "stop hook silent when not due"       '[ -z "$STOP_OUT" ]'
for f in q1 q2 q3 q4 q5; do bash "$H" edit "$T" "$T/$f.go" >/dev/null; done
STOP_OUT=$(jq -nc --arg c "$T" '{cwd:$c, stop_hook_active:false}' | bash "$H" stop)
check "quiet mode: stop prints nothing when due" '[ -z "$STOP_OUT" ]'
check "quiet mode: checkpoint stored as pending" 'grep -q "q1.go, q2.go" "$M/.checkpoint-pending.md"'
PROMPT_OUT=$(jq -nc --arg c "$T" '{cwd:$c, prompt:"now refactor the parser module please"}' | bash "$H" prompt | jq -r ".hookSpecificOutput.additionalContext")
check "quiet mode: next prompt carries the checkpoint" 'printf "%s" "$PROMPT_OUT" | grep -q "Before handling the request below" && printf "%s" "$PROMPT_OUT" | grep -q "q3.go"'
check "quiet mode: pending cleared after delivery" '[ ! -f "$M/.checkpoint-pending.md" ]'
for f in b1 b2 b3 b4 b5; do bash "$H" edit "$T" "$T/$f.go" >/dev/null; done
BLOCK_OUT=$(jq -nc --arg c "$T" '{cwd:$c, stop_hook_active:false}' | MEMLOG_CHECKPOINT_MODE=block bash "$H" stop)
check "block mode: stop returns decision block" 'printf "%s" "$BLOCK_OUT" | jq -e ".decision == \"block\"" >/dev/null && [ ! -f "$M/.checkpoint-pending.md" ]'

echo "adapters"
A="$ROOT/adapters"
check "cursor beforeSubmitPrompt continues" 'jq -nc --arg r "$T" "{workspace_roots:[\$r], prompt:\"hello there world\"}" | bash "$A/cursor/cursor-hook.sh" beforeSubmitPrompt | jq -e ".continue" >/dev/null'
check "cursor afterFileEdit logs"           'jq -nc --arg r "$T" "{workspace_roots:[\$r], file_path:(\$r+\"/c1.ts\")}" | bash "$A/cursor/cursor-hook.sh" afterFileEdit; grep -q "Edit c1.ts" "$M"/log/*.md'
check "gemini AfterTool logs write_file"    'jq -nc --arg r "$T" "{cwd:\$r, tool_name:\"write_file\", tool_input:{file_path:(\$r+\"/g1.py\")}}" | bash "$A/gemini/gemini-hook.sh" AfterTool; grep -q "write_file g1.py" "$M"/log/*.md'
check "gemini BeforeAgent injects"          'jq -nc --arg r "$T" "{cwd:\$r, prompt:\"what did we decide about client ids\"}" | bash "$A/gemini/gemini-hook.sh" BeforeAgent | jq -e ".hookSpecificOutput.additionalContext" >/dev/null'
( cd "$T" && git init -q && printf 'x\n' > tracked.go && git add . && git -c user.name=t -c user.email=t@t commit -qm init && printf 'y\n' >> tracked.go && printf 'n\n' > untracked.go )
bash "$A/codex/notify.sh" "{\"type\":\"agent-turn-complete\",\"input-messages\":[\"fix the parser\"],\"cwd\":\"$T\"}"
check "codex notify logs changed files"     'grep -q "Edit tracked.go" "$M"/log/*.md && grep -q "Edit untracked.go" "$M"/log/*.md'
BEFORE=$(grep -c "Edit tracked.go" "$M"/log/*.md); bash "$A/codex/notify.sh" "{\"type\":\"agent-turn-complete\",\"input-messages\":[],\"cwd\":\"$T\"}"
check "codex notify dedupes unchanged files" '[ "$(grep -c "Edit tracked.go" "$M"/log/*.md)" = "$BEFORE" ]'
if command -v node >/dev/null; then check "opencode plugin syntax" 'node --check "$A/opencode/local-memory.js" 2>/dev/null'; fi
if command -v bun >/dev/null; then check "pi extension syntax" 'bun build "$A/pi/local-memory.ts" --target=node --external "*" --outfile=/dev/null >/dev/null 2>&1'; fi

echo "mcp server"
python3 - "$ROOT" "$T" <<'EOF' && ok "initialize, tools/list, context, checkpoint, search round-trip" || fail "mcp round-trip"
import json, subprocess, sys, os
root, proj = sys.argv[1], sys.argv[2]
p = subprocess.Popen([sys.executable, os.path.join(root, "scripts", "mcp_server.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, cwd=proj)
def call(i, m, params=None):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": m, "params": params or {}}) + "\n"); p.stdin.flush(); return json.loads(p.stdout.readline())
assert call(1, "initialize", {"protocolVersion": "2025-06-18"})["result"]["serverInfo"]["name"] == "local-memory"
assert "memory_checkpoint" in [t["name"] for t in call(2, "tools/list")["result"]["tools"]]
r = call(3, "tools/call", {"name": "memory_checkpoint", "arguments": {"request": "mcp test", "files": ["m.go"], "learned": "l", "completed": "c", "next_steps": "n", "observations": [{"type": "feature", "title": "MCP checkpoint works", "facts": "m.go"}]}})
assert not r["result"]["isError"]
assert "MCP checkpoint works" in call(4, "tools/call", {"name": "memory_search", "arguments": {"query": "does the mcp checkpoint work", "limit": 3}})["result"]["content"][0]["text"]
assert "mcp test" in call(5, "tools/call", {"name": "memory_context", "arguments": {"task": "anything at all here"}})["result"]["content"][0]["text"]
p.stdin.close(); p.wait(timeout=10)
EOF

rm -rf "$TMP"
echo; echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
