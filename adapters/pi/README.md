# Pi adapter

**Status: written against the Pi coding agent extension API reference; not yet verified end to end.**

Pi is extended with TypeScript extensions that receive lifecycle events and can inject messages, which covers
everything the Claude Code hooks do. Pi does not use MCP, so the extension is the whole integration.

## Setup

1. Copy `local-memory.ts` to `~/.pi/agent/extensions/` (all projects) or `<project>/.pi/extensions/`.
2. Point it at this repo, either by editing `REPO` at the top of the file or by exporting
   `LOCAL_MEMORY_DIR=/ABSOLUTE/PATH/TO/claude-local-memory`.
3. Restart Pi. `/reload` also works on recent versions.

| Pi event | What the adapter does |
|---|---|
| `session_start` | records the project path for the index |
| `before_agent_start` | logs the prompt; injects the last checkpoint (first turn) and the top matching past entries as a hidden message |
| `tool_call` (`write`, `edit`, `bash`) | logs edits and state-changing commands |
| `agent_end` | if a checkpoint is due, sends the checkpoint request as the next user message |

## Notes

- The extension shells out to `scripts/memlog.sh` through `pi.exec`; `jq` and `python3` must be on PATH.
- Tool names and input fields follow Pi's built-in tools (`write` with `path`, `edit` with `path`, `bash` with
  `command`). If your version differs, adjust the three lines in the `tool_call` handler.
- The viewer is available from any terminal: `bash scripts/memlog.sh ui`.
