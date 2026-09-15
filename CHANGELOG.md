# Changelog

## 0.2.1 — 2026-09-15

- Checkpoints are now delivered quietly by default: the Stop hook stores the request and the next prompt
  injects it as context, so Claude Code no longer prints the whole request as a "Stop hook error".
  `MEMLOG_CHECKPOINT_MODE=block` restores the previous behaviour. A request left over when a session ends is
  delivered at the next session start with a note to reconstruct from the day log.

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
- Viewer reachable at `http://codingagentmemory.local:37701/`: it publishes the name through Bonjour
  (macOS) or Avahi (Linux) while running, no root needed. `scripts/friendly-url.sh` forwards port 80 for a
  portless address and prints the Windows hosts-file steps.
- Offline test suite (`tests/run.sh`), architecture and adapter docs, contributing guide, and a
  step-by-step install guide (`docs/INSTALL.md`). The Claude Code install path was executed end to end:
  marketplace add, plugin install, hooks firing in a headless session.
- Fixed: a single-line join dropped its only line on BSD sed; CLI modes blocked on stdin in a terminal;
  observations file was indexed twice.

## 0.1.0 — 2026-09-15

- First packaging as a Claude Code plugin: four hooks, three slash commands, optional vector setup, viewer,
  import from a claude-mem database.
