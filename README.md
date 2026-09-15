# local-memory

Persistent, searchable memory for coding agents that runs entirely on your machine and your existing
subscription. No background worker, no second model, no API keys, no cloud.

Works with **Claude Code** (verified), and ships adapters for **Cursor, Codex CLI, Gemini CLI, OpenCode,
and Pi** (written against their extension references, awaiting field reports — see `docs/ADAPTERS.md`).
All tools share the same memory for a project.

## How it works

1. **Capture.** Hooks log every prompt, file edit, and state-changing command to per-project Markdown day logs.
2. **Checkpoint.** Every 5 changes, the agent that did the work pauses for one short turn and is handed the
   exact list of files it changed. It writes a session entry (files, learned, completed, next steps) and 1-6
   typed observations: `discovery`, `change`, `feature`, `bugfix`, `decision`, `refactor`.
3. **Index.** Everything lands in one SQLite file: full-text search (BM25) always, vector search after an
   optional one-time setup. Ranking is hybrid.
4. **Retrieve.** At session start the agent gets the last checkpoint. On every prompt it gets the top five
   matching entries for the current project, capped to ~1,800 characters. Nothing else is read.
5. **Browse.** A single-command local viewer at `http://codingagentmemory.local:37701/` with timeline,
   project, kind and date filters, and search. The name is published through Bonjour while it runs; no setup.

The memory is Markdown you can read and edit, in the same folder Claude Code uses for its built-in memory:
`~/.claude/projects/<project>/memory/`. The index is a derived copy at `~/.claude-memory/index.db`.

## Install for Claude Code

```bash
claude plugin marketplace add <your-github-user>/claude-local-memory
claude plugin install local-memory@local-memory
```

Requirements: `jq` (ships with macOS 15+; otherwise `brew install jq` / `apt install jq`) and `python3`.
Keyword search works immediately. Hooks load on the next session you start. For semantic search, run once:

```bash
bash ~/.claude/plugins/cache/local-memory/local-memory/*/scripts/setup.sh
```

That creates `~/.claude-memory/venv` (about 150 MB: `sqlite-vec`, `fastembed`), downloads a 64 MB embedding
model, and embeds what is already indexed.

Slash commands: `/memory-search <text>`, `/memory-ui`, `/memory-forget`.

## Install for other tools

Clone the repo, then follow the README in the adapter folder:

| Tool | Folder | Mechanism |
|---|---|---|
| Cursor | `adapters/cursor` | hooks for capture and checkpoints, MCP for retrieval |
| Codex CLI | `adapters/codex` | `notify` for capture, MCP for retrieval and checkpoints |
| Gemini CLI | `adapters/gemini` | hooks for everything, MCP optional |
| OpenCode | `adapters/opencode` | plugin for everything, MCP optional |
| Pi | `adapters/pi` | extension for everything |
| Anything with MCP | `scripts/mcp_server.py` + `adapters/AGENTS-snippet.md` | retrieval and checkpoints without hooks |

## Command line

From `scripts/memlog.sh`:

```bash
bash scripts/memlog.sh search "stripe webhook signature"   # hybrid search, current project
bash scripts/memlog.sh ui                                  # viewer at http://codingagentmemory.local:37701/
bash scripts/memlog.sh projects                            # what is indexed, and whether each folder still exists
bash scripts/memlog.sh forget ~/old-project --files        # drop a project and its memory folder
bash scripts/memlog.sh prune                               # dry run: projects whose folder is gone
```

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `MEMLOG_SUMMARY_EVERY` | `5` | logged changes between checkpoints |
| `MEMLOG_RETRIEVE_N` | `5` | entries injected per prompt |
| `MEMLOG_CHECKPOINT_MODE` | `quiet` | `quiet`: checkpoint delivered silently on the next prompt; `block`: agent held at stop (Claude Code prints the request in the terminal) |
| `MEMINDEX_NOVEC` | unset | `1` forces keyword-only ranking |
| `MEMINDEX_DB` | `~/.claude-memory/index.db` | index location |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | where per-project memory folders live |
| `MEMORY_PROJECT_DIR` | server cwd | project for the MCP server |

## What a checkpoint looks like

```markdown
## 2026-09-15 11:13 — wire stripe webhook signature check
**Files:** src/payments/stripe_webhook.ts, src/payments/types.ts
**Learned:** the signature must be computed over the raw body, not the parsed JSON
**Completed:** verification added in stripe_webhook.ts; types extended
**Next steps:** add replay protection
```

```markdown
## 2026-09-15 11:13
- [bugfix] Webhook signature failed on parsed body — stripe_webhook.ts now hashes the raw request body
- [decision] No replay cache yet — deferred until idempotency keys land
```

Each observation line becomes its own indexed, embedded entry with its type as the kind.

## Migrating from claude-mem

```bash
python3 scripts/memindex.py seed ~/.claude-mem/claude-mem.db
```

## Why not an observer model

Observer-style memory runs a second model over your tool output after every call. That doubles usage and
adds a daemon that can fail or exhaust your quota. Here the session that did the work writes the memory, with
full context of why, at a cadence you choose. The trade-off is batching: memories are written every few
changes rather than after every tool call.

## Docs

- `docs/INSTALL.md` — step-by-step install, verification, troubleshooting, and uninstall for every tool
- `docs/ARCHITECTURE.md` — storage layout, ranking, how checkpoints are delivered per tool
- `docs/ADAPTERS.md` — support matrix and how to add an adapter
- `docs/TESTING.md` — offline suite and how to verify an adapter in its tool
- `CONTRIBUTING.md`, `CHANGELOG.md`

## License

MIT
