# Cursor adapter

**Status: written against the Cursor hooks reference (hooks.json v1); not yet verified end to end.**
Please open an issue with your Cursor version if an event name or field differs.

Cursor gives two things: hooks (for capture and checkpoints) and MCP (for retrieval).

## 1. Hooks: capture and checkpoints

Copy `hooks.json` to `~/.cursor/hooks.json` (all projects) or `<project>/.cursor/hooks.json` (one project),
and replace `/ABSOLUTE/PATH/TO/claude-local-memory` with where you cloned this repo. Restart Cursor.

| Cursor event | What the adapter does |
|---|---|
| `beforeSubmitPrompt` | logs the prompt to the day log, returns `{"continue": true}` |
| `afterFileEdit` | logs the edited file and indexes it |
| `afterShellExecution` | logs state-changing commands (read-only ones are skipped) |
| `stop` | if a checkpoint is due, returns `followup_message` with the checkpoint instructions, which Cursor sends to the agent as the next turn |

The working directory is taken from `workspace_roots[0]`.

## 2. MCP: retrieval

Add the server to `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "local-memory": {
      "command": "python3",
      "args": ["/ABSOLUTE/PATH/TO/claude-local-memory/scripts/mcp_server.py"]
    }
  }
}
```

Use the venv interpreter (`~/.claude-memory/venv/bin/python`) instead of `python3` after running `scripts/setup.sh`
if you want vector search. Cursor starts MCP servers in the workspace, so the project is detected automatically.

Then copy `local-memory.mdc` into `<project>/.cursor/rules/`. It tells the agent to call `memory_context` at the
start of each task and `memory_checkpoint` when one is due.

## Why retrieval is not done in the hook

Cursor's `beforeSubmitPrompt` can allow or block a prompt but cannot add context to it. The MCP route gives the
agent the same retrieval on demand, and the rule makes it routine.
