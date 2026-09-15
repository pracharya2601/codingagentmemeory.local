# Testing

## Offline suite

```bash
bash tests/run.sh
```

Runs in a temporary directory with its own index and config folder, so it never touches your memory.
Covers the core (logging, checkpoint window and arming, retrieval, sync idempotence), the Claude Code hook
modes, the shell adapters with synthetic payloads (Cursor, Gemini CLI, Codex), syntax of the OpenCode and Pi
adapters, and a full MCP round-trip. Needs `bash`, `jq`, `python3`; `node` and `bun` add the syntax checks.

Vector search is disabled in the suite (`MEMINDEX_NOVEC=1`) so it runs without the optional environment.

## Testing an adapter inside its tool

Each adapter README lists its status. To verify one for real:

1. Install the adapter as described, pointing at your clone.
2. Open a scratch project in the tool and make a small edit.
3. Check the day log: `cat ~/.claude/projects/<slug>/memory/log/$(date +%F).md` should show the edit.
4. Make five changes. On the next turn end the checkpoint request should reach the agent and it should append
   to `session-log.md` and `observations.md`.
5. Ask a question about something you did. The injected context (or the agent's `memory_context` call) should
   surface it.
6. Open `bash scripts/memlog.sh ui` and confirm the entries show under the right kinds.

Please report results as an issue with the tool name and version, whichever way it went. Field names and
event names are the parts most likely to differ between versions, and they're one-line fixes.

## Manual checks for the core

```bash
S=scripts/memlog.sh; P=/tmp/lm-scratch; mkdir -p $P
bash $S edit $P $P/x.go; bash $S edit $P $P/y.go; bash $S edit $P $P/z.go; bash $S edit $P $P/w.go; bash $S edit $P $P/v.go
bash $S due $P            # prints the checkpoint request with the five files
bash $S retrieve $P "what happened to the x file"
python3 scripts/memindex.py forget $P --files; rm -rf $P
```
