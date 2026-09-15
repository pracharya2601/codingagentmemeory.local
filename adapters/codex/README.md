# Codex CLI adapter

**Status: written against the Codex CLI configuration reference (`notify` and `mcp_servers` in `config.toml`); not yet verified end to end.**

Codex has no per-tool hooks and no way to inject context from a shell hook, so this adapter uses two of its
extension points:

- **`notify`** for capture: Codex runs a command after every agent turn with the turn's JSON payload. The
  adapter logs the user's messages and detects changed files via `git status` plus modification times.
- **MCP** for retrieval and checkpoints: the `local-memory` server gives the agent `memory_context`,
  `memory_search`, and `memory_checkpoint`. An `AGENTS.md` instruction makes the agent call them.

## Setup

In `~/.codex/config.toml`:

```toml
notify = ["bash", "/ABSOLUTE/PATH/TO/claude-local-memory/adapters/codex/notify.sh"]

[mcp_servers.local-memory]
command = "python3"
args = ["/ABSOLUTE/PATH/TO/claude-local-memory/scripts/mcp_server.py"]
```

If you already have a `notify` command, wrap both in a small script; Codex accepts one.

Use `~/.claude-memory/venv/bin/python` instead of `python3` after `scripts/setup.sh` to get vector search.

The MCP server takes the project from its working directory. If Codex starts servers outside the project on
your version, set it explicitly:

```toml
[mcp_servers.local-memory.env]
MEMORY_PROJECT_DIR = "/path/to/project"
```

Then add the contents of `../AGENTS-snippet.md` to your project's `AGENTS.md` (or `~/.codex/AGENTS.md` for all
projects).

## What you get

| Capability | How |
|---|---|
| Prompt logging | `notify` payload `input-messages` |
| File change logging | `git status` at turn end, deduplicated by mtime; one row per changed file |
| Retrieval | `memory_context` at the start of each turn, `memory_search` on demand |
| Checkpoints | `memory_context` reports when one is due; the agent calls `memory_checkpoint` |
| Viewer | `bash scripts/memlog.sh ui` from any terminal |

Files outside git and shell commands are not captured on Codex, since `notify` does not carry tool calls.
