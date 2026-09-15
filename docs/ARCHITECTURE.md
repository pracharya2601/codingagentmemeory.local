# Architecture

local-memory is three layers. Only the top one knows which agent you're using.

```
┌──────────────────────────────────────────────────────────────────────┐
│ Adapters      Claude Code plugin · Cursor hooks · Codex notify+MCP     │
│               Gemini CLI hooks · OpenCode plugin · Pi extension · MCP  │
├──────────────────────────────────────────────────────────────────────┤
│ Core          scripts/memlog.sh   note · edit · cmd · retrieve · last  │
│                                   sync · due · search · ui · forget    │
│               scripts/mcp_server.py   the same operations as MCP tools │
├──────────────────────────────────────────────────────────────────────┤
│ Storage       Markdown per project (source of truth, human-editable)   │
│               SQLite index (derived: FTS5 + optional sqlite-vec)       │
└──────────────────────────────────────────────────────────────────────┘
```

## Storage

**Markdown, one folder per project** at `<config>/projects/<slug>/memory/` where `<config>` is
`~/.claude` (or `CLAUDE_CONFIG_DIR`) and `<slug>` is the project path with every non-alphanumeric character
replaced by `-`. This is the same folder Claude Code uses for its built-in memory, so the two coexist.

| File | Written by | Purpose |
|---|---|---|
| `MEMORY.md` | agent / core | short index, one line per memory; loaded by Claude Code every session |
| `session-log.md` | agent at checkpoints | dated entries: request, files, learned, completed, next steps |
| `observations.md` | agent at checkpoints | dated blocks of typed one-liners: discovery, change, feature, bugfix, decision, refactor |
| `log/YYYY-MM-DD.md` | core | raw activity: prompts, edits, commands, checkpoint boundaries |
| `*.md` (any other) | agent / you | durable memories with frontmatter (`name`, `description`, `type`) |

**SQLite index** at `~/.claude-memory/index.db` (override with `MEMINDEX_DB`):

| Table | Contents |
|---|---|
| `entries` | one row per memory unit: project, timestamp, kind, title, body, dedupe hash |
| `entries_fts` | FTS5 over title and body, porter stemming, BM25 ranking |
| `entries_vec` | sqlite-vec, 384-dim embeddings (BAAI/bge-small-en-v1.5 via fastembed), only after `setup.sh` |
| `vec_done` | which rows have a vector |
| `projects` | slug → real path, so a project can be found and forgotten after its folder is deleted |

Every Markdown unit maps to rows: a session entry is one row of kind `session`; each observation line is one
row with its type as the kind; each memory file is one row of kind `memory:<type>`; each edit or command is one
row. Rows carry a content hash, so re-syncing is idempotent and an edited memory file replaces its old row.

## Core operations (`scripts/memlog.sh`)

| Mode | Effect |
|---|---|
| `note <cwd> <text>` | append the prompt to the day log |
| `edit <cwd> <path> [tool]` | append to the day log and insert an `edit` row |
| `cmd <cwd> <command>` | same for state-changing commands; read-only commands are ignored by a prefix allowlist |
| `retrieve <cwd> <text> [n]` | hybrid search scoped to the project; empty for slash commands and prompts under three words; output capped at 1,800 characters |
| `last <cwd>` | latest `session` row |
| `sync <cwd>` | parse session-log, observations, and memory files into rows; embed rows that lack a vector |
| `due <cwd>` | if changes since the last checkpoint ≥ `MEMLOG_SUMMARY_EVERY` (default 5): write a boundary to the day log, arm the marker, and print the checkpoint instructions with the exact file and command list for the window |

`memindex.py` owns the database and is also a CLI (`query`, `seed`, `stats`, `forget`, `prune`, `embed`, …).

## Ranking

`query()` runs BM25 over `entries_fts` and, when vectors are available, a nearest-neighbour search over
`entries_vec` for the embedded query. The two ranked lists are merged with reciprocal rank fusion
(`score = Σ 1/(60 + rank)`), then filtered by project, kind, and date. Modes: `hybrid` (default), `keyword`, `meaning`.

Measured on a 4,000-row index on an M-series laptop: keyword query ≈ 50 ms; hybrid ≈ 380 ms, almost all of it
the one-time model load per process.

## The checkpoint

This is the part that replaces an observer model. After N logged changes, the next time the agent finishes a
turn the adapter hands it the list of files and commands from that window and asks for two writes: a session
entry and typed observations. The agent that did the work writes the memory with full context of why, at a
cost of one short turn per N changes. Adapters deliver the request differently:

| Adapter | Delivery |
|---|---|
| Claude Code | quiet (default): the `Stop` hook stores the request and the next `UserPromptSubmit` injects it as context, so nothing is printed in the terminal; `MEMLOG_CHECKPOINT_MODE=block` instead holds the agent at stop (Claude Code prints the request as a "hook error") |
| Cursor | `stop` hook returns `followup_message` |
| Gemini CLI | `AfterAgent` hook returns `decision: block` |
| OpenCode | plugin sends a follow-up prompt on `session.idle` |
| Pi | extension calls `sendUserMessage` on `agent_end` |
| Codex / any MCP client | `memory_context` reports the checkpoint; the agent calls `memory_checkpoint` |

`due` arms a marker when it fires, so the request is delivered once per window even if several hooks ask.

## MCP server (`scripts/mcp_server.py`)

A dependency-free MCP stdio server exposing `memory_context`, `memory_search`, `memory_last`,
`memory_recent`, `memory_checkpoint`, `memory_log_edit`, `memory_note`. It shells out to `memlog.sh`, so its
behaviour is identical to the hooks. The project is the server's working directory or `MEMORY_PROJECT_DIR`.

## Viewer (`scripts/memview.py`)

A single-file HTTP server bound to 127.0.0.1 that serves one page: project sidebar, timeline, kind and date
filters, and search in all three ranking modes. It reads the index at request time and stops when you close it.

## Trust boundary

Everything retrieved is injected as *context*, never as instructions, and every injection is prefixed with a
line telling the agent to verify against the repository. Memory rows come from your own sessions and the
files in your memory folders; nothing is fetched from the network.
