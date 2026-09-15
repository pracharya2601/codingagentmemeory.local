# local-memory

Persistent, searchable memory for [Claude Code](https://claude.com/claude-code) that runs entirely on your
Claude subscription. No background worker, no second model, no API keys, no cloud.

- **Capture.** Hooks log every prompt, file edit, and state-changing command to per-project Markdown day logs.
- **Observe.** Every 5 changes your *own session* pauses for one short turn and writes a checkpoint: a
  session entry (files touched, learned, completed, next steps) plus typed observations
  (`discovery`, `change`, `feature`, `bugfix`, `decision`, `refactor`).
- **Index.** Everything lands in one SQLite file with full-text search (BM25) and, after an optional setup,
  vector search (sqlite-vec + a local bge-small model). Ranking is hybrid via reciprocal rank fusion.
- **Retrieve.** At session start Claude gets the last checkpoint. On every prompt it gets the top five
  matching entries for the current project, capped to ~1,800 characters. Nothing else is read.
- **Browse.** `/memory-ui` opens an on-demand local viewer with a timeline, project/kind/date filters, and
  hybrid search. It stops when you close it.

Everything stays on disk under `~/.claude/projects/<project>/memory/` (Markdown you can edit) and
`~/.claude-memory/index.db` (the derived search index).

## Install

```bash
claude plugin marketplace add <your-github-user>/claude-local-memory
claude plugin install local-memory@local-memory
```

Requirements: `jq` and `python3` (both standard on macOS; `apt install jq` on Debian/Ubuntu).
Keyword search works immediately. For semantic search, run once:

```bash
bash ~/.claude/plugins/cache/local-memory/local-memory/*/scripts/setup.sh
```

It creates `~/.claude-memory/venv` (about 150 MB with `sqlite-vec` and `fastembed`), downloads the
64 MB embedding model, and embeds what is already indexed. `uv` is used if present, otherwise `python3 -m venv`.

## Commands

| Command | What it does |
|---|---|
| `/memory-search <text>` | Hybrid search of the current project's memory, summarized by Claude |
| `/memory-ui` | Start the browser viewer at http://127.0.0.1:37701 |
| `/memory-forget [path \| --prune] [--files]` | Remove a project from the index, or prune projects whose folder is gone |

The same operations are available from the shell via `scripts/memlog.sh`:
`search`, `projects`, `forget`, `prune`, `ui`.

## Configuration

Environment variables, set in your shell or in `settings.json` under `env`:

| Variable | Default | Meaning |
|---|---|---|
| `MEMLOG_SUMMARY_EVERY` | `5` | Logged changes between checkpoints |
| `MEMLOG_RETRIEVE_N` | `5` | Entries injected per prompt |
| `MEMINDEX_NOVEC` | unset | Set to `1` to force keyword-only ranking |
| `MEMINDEX_DB` | `~/.claude-memory/index.db` | Index location |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Honoured for the project memory folders |

## How a checkpoint works

After the fifth logged change, the next time Claude finishes a turn the Stop hook holds it for one more
step and hands it the exact list of files and commands from that window. Claude appends:

```markdown
## 2026-09-15 11:13 — wire stripe webhook signature check
**Files:** src/payments/stripe_webhook.ts, src/payments/types.ts
**Learned:** the signature must be computed over the raw body, not the parsed JSON
**Completed:** verification added in stripe_webhook.ts; types extended
**Next steps:** add replay protection
```

and, to `observations.md`:

```markdown
## 2026-09-15 11:13
- [bugfix] Webhook signature failed on parsed body — stripe_webhook.ts now hashes the raw request body
- [decision] No replay cache yet — deferred until idempotency keys land
```

Each observation line becomes its own indexed, embedded entry with its type as the kind.
A `### checkpoint` marker is also written into the day log so raw activity reads as windows.

## Migrating from claude-mem

If you have a claude-mem database, import it once:

```bash
python3 scripts/memindex.py seed ~/.claude-mem/claude-mem.db
```

Projects are matched by name to `~/.claude/projects/*`. For names that cannot be matched automatically,
set `MEMINDEX_SEED_OVERRIDES='{"name": "-Users-you-path-slug"}'`.

## Why not a background observer

Observer-style memory tools run a second model over your tool output. That doubles your usage and adds
a daemon that can fail. Here the session that did the work writes the memory, at a cadence you choose,
with full context of why it did what it did. The trade-off is that memories are written in batches of
changes rather than after every tool call.

## Uninstall

```bash
claude plugin uninstall local-memory@local-memory
```

Your Markdown memory folders are left in place. Delete `~/.claude-memory` to drop the index, model, and
Python environment.

## License

MIT
