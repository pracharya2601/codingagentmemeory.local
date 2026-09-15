# local-memory

Persistent, searchable memory for coding agents that runs entirely on your machine and your existing
subscription. No background worker, no second model, no API keys, no cloud.

Works with **Claude Code** (verified), and ships adapters for **Cursor, Codex CLI, Gemini CLI, OpenCode,
and Pi** (written against their extension references, awaiting field reports — see `docs/ADAPTERS.md`).
All tools share the same memory for a project.

## How it works

1. **Capture.** Hooks log every prompt, file edit, and state-changing command to per-project Markdown day logs.
2. **Checkpoint.** Every 5 changes, the agent that did the work is handed the exact list of files it changed
   and writes a session entry (files, learned, completed, next steps) plus 1-6 typed observations:
   `discovery`, `change`, `feature`, `bugfix`, `decision`, `refactor`. Delivered quietly at the start of
   the next prompt; nothing is printed in the terminal.
3. **Index.** Everything lands in one SQLite file: full-text search (BM25) always, vector search after an
   optional one-time setup. Ranking is hybrid.
4. **Retrieve.** At session start the agent gets the last checkpoint. On every prompt it gets the top five
   matching entries for the current project, capped to ~1,800 characters. Nothing else is read.
5. **Browse.** A local viewer at `http://codingagentmemory.local/` with timeline, project, kind and date
   filters, and search.

The memory is Markdown you can read and edit, in the same folder Claude Code uses for its built-in memory:
`~/.claude/projects/<project>/memory/`. The index is a derived copy at `~/.claude-memory/index.db`.

## Install (Claude Code)

```bash
claude plugin marketplace add pracharya2601/codingagentmemeory.local
claude plugin install local-memory@local-memory
```

Requirements: `jq` (ships with macOS 15+; otherwise `brew install jq` / `apt install jq`) and `python3`.
Start a new session and it's on. Keyword search works immediately; for semantic search run once:

```bash
bash ~/.claude/plugins/cache/local-memory/local-memory/*/scripts/setup.sh
```

That creates `~/.claude-memory/venv` (about 150 MB: `sqlite-vec`, `fastembed`), downloads a 64 MB embedding
model, and embeds what is already indexed.

Other tools: clone the repo and follow the README in `adapters/<tool>/`. Full details, verification steps and
troubleshooting: `docs/INSTALL.md`.

## Using it day to day

### Nothing to do, mostly

Work as usual. In every project you'll notice three things:

- **Session start:** "Where this project was left" with the last checkpoint's next steps.
- **On prompts:** "Relevant past memory for this project" with up to five matching entries when there are any.
- **After every 5 logged changes:** at the start of your next prompt the agent first appends a checkpoint to
  `session-log.md` and `observations.md`, then handles your request. You'll see two small file writes.

If you want the agent to remember something specific, just say so ("remember that we deploy from `main`
only"). It writes a memory file and adds it to the project's `MEMORY.md` index.

### Slash commands

| Command | What it does |
|---|---|
| `/memory-search <text>` | Hybrid search of this project's memory, summarized. Example: `/memory-search why did we switch to token buckets` |
| `/memory-ui` | Opens the viewer in your browser. Reuses a running instance rather than starting another. |
| `/memory-forget` | Lists what's indexed and whether each project's folder still exists. |
| `/memory-forget --prune` | Dry run of removing projects whose folder is gone; applies only after you confirm. |
| `/memory-forget <path> [--files]` | Removes one project from the index, and its Markdown memory folder with `--files`. Asks first. |

If another plugin uses the same command names, the namespaced form always works: `/local-memory:memory-ui`.

### The viewer

`/memory-ui` opens `http://codingagentmemory.local:37701/`. The name needs no setup on macOS (the viewer
announces it through Bonjour while running), one `hosts` line on Windows, and the `avahi-utils` package on
Linux.

To drop the port, once per machine (asks for your password once, survives reboots):

```bash
bash ~/.claude/plugins/cache/local-memory/local-memory/*/scripts/friendly-url.sh install
```

Then it's `http://codingagentmemory.local/`. The viewer keeps running until you stop it:

```bash
pkill -f memview.py
```

In the viewer: pick a project in the sidebar, type and press Enter to search (choose hybrid, keywords only, or
meaning only), narrow by kind chips and date range, click a card to expand it.

### From the shell

The same operations without Claude, from inside a project directory:

```bash
M=~/.claude/plugins/cache/local-memory/local-memory/*/scripts/memlog.sh
bash $M search "stripe webhook signature"   # ranked search for this project
bash $M ui                                  # start the viewer (Ctrl-C stops it)
bash $M projects                            # every indexed project, with folder status
bash $M prune                               # dry run: projects whose folder is gone
bash $M prune --apply --files               # remove them, including their memory folders
bash $M forget ~/old-project --files        # remove one project
```

An alias saves typing: `alias mem='bash ~/.claude/plugins/cache/local-memory/local-memory/*/scripts/memlog.sh'`.

### Cleaning up old memory

- **A project you deleted:** `/memory-forget --prune` finds it and removes it after you confirm. Nothing is
  pruned automatically, and projects whose path the index doesn't know are never touched.
- **A memory that's wrong:** edit or delete the Markdown file under `~/.claude/projects/<project>/memory/`
  and remove its line from `MEMORY.md`. The index follows on the next stop.
- **Everything:** `rm -rf ~/.claude-memory` drops the index, the model and the Python environment. Your
  Markdown memory folders stay; re-running `setup.sh` rebuilds the index from them.

### Where the files are

```
~/.claude/projects/<project-slug>/memory/
  MEMORY.md          short index, one line per memory (loaded every session)
  session-log.md     checkpoints: request, files, learned, completed, next steps
  observations.md    typed one-liners written at checkpoints
  log/YYYY-MM-DD.md  raw activity: prompts, edits, commands, checkpoint boundaries
  *.md               durable memories the agent or you wrote
~/.claude-memory/
  index.db           SQLite: full-text + vector index over all of the above
  venv/ models/      optional, from setup.sh
```

The project slug is the project's absolute path with every non-alphanumeric character replaced by `-`.

### Updating and removing the plugin

```bash
claude plugin marketplace update local-memory && claude plugin update local-memory@local-memory
claude plugin uninstall local-memory@local-memory      # memory folders and index are left in place
```

Restart sessions after an update so they load the new files.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `MEMLOG_SUMMARY_EVERY` | `5` | logged changes between checkpoints |
| `MEMLOG_RETRIEVE_N` | `5` | entries injected per prompt |
| `MEMLOG_CHECKPOINT_MODE` | `quiet` | `quiet`: checkpoint delivered silently on the next prompt; `block`: agent held at stop (Claude Code prints the request in the terminal) |
| `MEMVIEW_NAME` | `codingagentmemory.local` | name(s) the viewer publishes, comma-separated |
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
