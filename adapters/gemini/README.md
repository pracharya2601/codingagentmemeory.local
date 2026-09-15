# Gemini CLI adapter

**Status: written against the Gemini CLI hooks reference (`hooks` in `settings.json`); not yet verified end to end.**
Event and field names mirror Claude Code's. If your Gemini CLI version names them differently, the translator
in `gemini-hook.sh` is a 40-line switch and easy to adjust; please open an issue with what you found.

Gemini CLI supports both hooks and MCP, so the adapter uses hooks for everything and adds the MCP server as a
fallback for on-demand search.

## Setup

Merge `settings.hooks.json` into `~/.gemini/settings.json` (or `<project>/.gemini/settings.json`), replacing
`/ABSOLUTE/PATH/TO/claude-local-memory`. Use `~/.claude-memory/venv/bin/python` instead of `python3` after
`scripts/setup.sh` if you want vector search.

| Gemini event | What the adapter does |
|---|---|
| `SessionStart` | injects the latest checkpoint as additional context |
| `BeforeAgent` | logs the prompt, injects the top matching past entries |
| `AfterTool` (`write_file`, `replace`, `run_shell_command`) | logs edits and state-changing commands |
| `AfterAgent` | if a checkpoint is due, returns `decision: block` with the checkpoint instructions so the agent writes it before finishing |

Optionally add the contents of `../AGENTS-snippet.md` to `GEMINI.md` so the agent also uses the MCP tools.

## If `AfterAgent` cannot hold the agent on your version

Then checkpoints come from the MCP route instead: `memory_context` reports when one is due and the agent calls
`memory_checkpoint`. Keep the `GEMINI.md` instruction in that case.
