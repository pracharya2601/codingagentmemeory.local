# Changelog

## 0.2.0 — 2026-09-15

- Core split from the Claude Code plugin: `scripts/memlog.sh` gains argument-based modes (`note`, `edit`,
  `cmd`, `retrieve`, `last`, `sync`, `due`) so any tool can drive it.
- MCP server (`scripts/mcp_server.py`, no dependencies) exposing `memory_context`, `memory_search`,
  `memory_last`, `memory_recent`, `memory_checkpoint`, `memory_log_edit`, `memory_note`.
- Adapters for Cursor (hooks + MCP rule), Codex CLI (`notify` + MCP), Gemini CLI (hooks), OpenCode (plugin),
  Pi (extension). All written against published references; verification status tracked in `docs/ADAPTERS.md`.
- Checkpoints now carry the exact list of files and commands from their window, write a boundary into the day
  log, and ask for typed observations (discovery, change, feature, bugfix, decision, refactor) alongside the
  session entry. Default cadence is every 5 changes.
- Viewer: explicit search with three ranking modes, date range, kind chips, snippets, free-port fallback.
- Offline test suite (`tests/run.sh`), architecture and adapter docs, contributing guide.
- Fixed: a single-line join dropped its only line on BSD sed; CLI modes blocked on stdin in a terminal;
  observations file was indexed twice.

## 0.1.0 — 2026-09-15

- First packaging as a Claude Code plugin: four hooks, three slash commands, optional vector setup, viewer,
  import from a claude-mem database.
