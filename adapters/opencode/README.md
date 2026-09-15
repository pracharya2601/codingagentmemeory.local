# OpenCode adapter

**Status: written against the OpenCode plugin API reference; not yet verified end to end.**

OpenCode loads JavaScript plugins that receive tool and chat events, which is enough to do everything the Claude
Code hooks do: capture, retrieval injected into the prompt, and checkpoints as a follow-up prompt.

## Setup

1. Copy `local-memory.js` to `<project>/.opencode/plugins/` (one project) or `~/.config/opencode/plugins/` (all).
2. Tell it where this repo is, either by editing `REPO` at the top of the file or by exporting
   `LOCAL_MEMORY_DIR=/ABSOLUTE/PATH/TO/claude-local-memory` in your shell.
3. Restart OpenCode.

| OpenCode hook | What the adapter does |
|---|---|
| `tool.execute.before` (`edit`, `write`, `bash`) | logs edits and state-changing commands |
| `chat.message` | logs the prompt and appends retrieved memory as an extra text part |
| `event` → `session.idle` | if a checkpoint is due, sends the checkpoint request as a follow-up prompt via `client.session.prompt` |

## Optional: MCP

OpenCode also supports MCP servers. Add to `opencode.json` if you want the agent to search on demand:

```json
{
  "mcp": {
    "local-memory": {
      "type": "local",
      "command": ["python3", "/ABSOLUTE/PATH/TO/claude-local-memory/scripts/mcp_server.py"],
      "enabled": true
    }
  }
}
```

Use `~/.claude-memory/venv/bin/python` instead of `python3` after `scripts/setup.sh` for vector search.

## Notes

- The plugin shells out to `scripts/memlog.sh`; `jq` and `python3` must be on PATH.
- If `client.session.prompt` is not available on your version, checkpoints stay armed and are delivered the
  next time the agent calls `memory_context` through MCP. Add `../AGENTS-snippet.md` to your `AGENTS.md` in that case.
