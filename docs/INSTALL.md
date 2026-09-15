# Installation

This guide covers every supported tool. Only the Claude Code path has been run end to end so far; the others
follow each tool's published extension reference and are marked accordingly. Whatever you install, the
memory itself lives in the same two places, so several tools can share it:

- `~/.claude/projects/<project-slug>/memory/` — Markdown you can read and edit
- `~/.claude-memory/index.db` — the derived search index

## Prerequisites

| Requirement | Why | Check |
|---|---|---|
| `bash` | the core is a shell script | `bash --version` |
| `jq` | parses hook payloads | `jq --version` (ships with macOS 15+; otherwise `brew install jq` or `apt install jq`) |
| `python3` 3.9+ with SQLite FTS5 | the index | `python3 -c "import sqlite3,sys;c=sqlite3.connect(':memory:');c.execute('create virtual table t using fts5(a)');print('ok')"` |
| `git` | Codex adapter only | `git --version` |

Optional, for semantic (vector) search: `uv` speeds up the environment creation but plain `python3 -m venv`
works too. Roughly 150 MB for the environment plus a 64 MB model download, one time.

---

## Claude Code — verified

### 1. Install the plugin

```bash
claude plugin marketplace add pracharya2601/codingagentmemeory.local
claude plugin install local-memory@local-memory
```

From a local clone instead of GitHub:

```bash
claude plugin marketplace add /path/to/claude-local-memory
claude plugin install local-memory@local-memory
```

What this does: registers the four hooks (session start, prompt, tool use, stop) and three slash commands.
The plugin is copied to `~/.claude/plugins/cache/local-memory/local-memory/<version>/`.

### 2. Start a new session

Hooks load when a session starts. Open any project and run Claude Code. On the first session you'll see a
one-line note that keyword search is active and how to enable vectors. From the second session in a project
you'll see "Where this project was left" at start and "Relevant past memory" injected on prompts that have
matches.

### 3. Optional: enable semantic search

```bash
bash ~/.claude/plugins/cache/local-memory/local-memory/*/scripts/setup.sh
```

Run it once. It builds `~/.claude-memory/venv`, downloads the embedding model, and embeds everything already
indexed. Subsequent prompts use hybrid ranking automatically; nothing else to configure.

### 4. Verify

```bash
# after making a couple of edits in a project:
cat ~/.claude/projects/$(pwd | sed 's/[^A-Za-z0-9-]/-/g')/memory/log/$(date +%F).md
bash ~/.claude/plugins/cache/local-memory/local-memory/*/scripts/memlog.sh projects
```

The first shows the day log with your prompts and edits. The second lists indexed projects. After five
logged changes, the next time Claude finishes a turn it will write a checkpoint; you'll see it appear in
`session-log.md` and `observations.md` in the same folder.

Slash commands: `/memory-search <text>`, `/memory-ui`, `/memory-forget`.

### Notes

- **Do not also wire the hooks by hand in `settings.json`.** The plugin already registers them; having both
  logs every event twice.
- The project slug is derived from the **resolved** path. A project under a symlinked directory (for example
  `/var/...` on macOS, which resolves to `/private/var/...`) gets its slug from the resolved form.
- `CLAUDE_CONFIG_DIR` is honoured if you relocate your Claude config.

### Uninstall

```bash
claude plugin uninstall local-memory@local-memory
claude plugin marketplace remove local-memory
```

Memory folders are left in place. `rm -rf ~/.claude-memory` removes the index, model, and environment.

---

## Cursor — untested

See `adapters/cursor/README.md`. Summary:

1. Clone this repo somewhere permanent, e.g. `~/claude-local-memory`.
2. Copy `adapters/cursor/hooks.json` to `~/.cursor/hooks.json` (or `<project>/.cursor/hooks.json`) and replace
   `/ABSOLUTE/PATH/TO/claude-local-memory` with the clone path.
3. Add the MCP server to `~/.cursor/mcp.json` (snippet in the adapter README).
4. Copy `adapters/cursor/local-memory.mdc` into `<project>/.cursor/rules/`.
5. Restart Cursor.

Capture and checkpoints come from hooks; retrieval comes from the MCP tools, prompted by the rule.

## Codex CLI — untested

See `adapters/codex/README.md`. Summary:

1. Clone the repo.
2. In `~/.codex/config.toml` set `notify` to `adapters/codex/notify.sh` and add the `local-memory` MCP server.
3. Append `adapters/AGENTS-snippet.md` to your `AGENTS.md`.

Codex has no per-tool hooks, so changed files are detected from `git status` at the end of each turn.

## Gemini CLI — untested

See `adapters/gemini/README.md`. Summary:

1. Clone the repo.
2. Merge `adapters/gemini/settings.hooks.json` into `~/.gemini/settings.json`, replacing the placeholder path.
3. Optionally append `adapters/AGENTS-snippet.md` to `GEMINI.md`.

## OpenCode — untested

See `adapters/opencode/README.md`. Summary:

1. Clone the repo.
2. Copy `adapters/opencode/local-memory.js` to `~/.config/opencode/plugins/` or `<project>/.opencode/plugins/`.
3. Set `LOCAL_MEMORY_DIR` to the clone path (or edit `REPO` in the file).
4. Restart OpenCode.

## Pi — untested

See `adapters/pi/README.md`. Summary:

1. Clone the repo.
2. Copy `adapters/pi/local-memory.ts` to `~/.pi/agent/extensions/` or `<project>/.pi/extensions/`.
3. Set `LOCAL_MEMORY_DIR` to the clone path (or edit `REPO` in the file).
4. Restart Pi.

## Any other MCP-capable agent

Register `scripts/mcp_server.py` as a stdio MCP server, started in the project directory (or with
`MEMORY_PROJECT_DIR` set), and add `adapters/AGENTS-snippet.md` to the agent's instructions. That gives
retrieval and checkpoints through tool calls, with no hooks.

---

## Migrating from claude-mem

```bash
python3 scripts/memindex.py seed ~/.claude-mem/claude-mem.db
```

Projects are matched by name to your `~/.claude/projects/*` folders. For names that don't match, set
`MEMINDEX_SEED_OVERRIDES='{"claude-mem-project-name": "-Users-you-path-slug"}'` and rerun; the seed is
idempotent.

## The viewer's address: `http://codingagentmemory.local:37701/`

The viewer publishes the name **`codingagentmemory.local`** itself every time it starts, so on macOS this
address works with no setup at all:

```bash
bash scripts/memlog.sh ui          # prints and opens http://codingagentmemory.local:37701/
```

How: `.local` is the Bonjour/mDNS domain. The viewer runs `dns-sd -P` (built into macOS, no root needed) to
announce the name as 127.0.0.1 for as long as it is running, and withdraws it on exit. Every browser on the
machine resolves it, because it goes through the system resolver. Verified on macOS 15 in Safari-engine and
Chromium browsers. The name may take a second or two to appear after start.

Other names: `bash scripts/memlog.sh ui 37701 memory.local,codingagentmemory.local` publishes several, or set
`MEMVIEW_NAME`. Names not ending in `.local` are not published; add them to your hosts file instead.

**Linux.** Same mechanism through Avahi: `sudo apt install avahi-utils` (or your distro's equivalent) once,
then the viewer publishes the name with `avahi-publish`. Without Avahi, add `127.0.0.1 codingagentmemory.local`
to `/etc/hosts`.

**Windows.** Windows resolves `.local` names through the hosts file first, so no Bonjour is needed:

1. Open Notepad as Administrator, open `C:\Windows\System32\drivers\etc\hosts`, add the line
   `127.0.0.1 codingagentmemory.local`, save.
2. Run the viewer under WSL2 or Git Bash: `bash scripts/memlog.sh ui`. WSL2 forwards localhost ports to
   Windows automatically, so the Windows browser reaches it.
3. Open `http://codingagentmemory.local:37701/`.

`bash scripts/friendly-url.sh windows` prints these steps.

### Dropping the port: `http://codingagentmemory.local/`

Port 80 needs administrator rights on macOS and Linux, so this is the one step that asks for a password.
Rather than run the viewer as root, forward port 80 to the viewer's port:

```bash
bash scripts/friendly-url.sh install     # macOS: forward 80 -> 37701 now and at every boot (one password prompt)
bash scripts/friendly-url.sh enable      # macOS/Linux: same, but only until reboot
bash scripts/friendly-url.sh disable     # remove it, including the boot job
```

`install` writes a packet-filter anchor file and a LaunchDaemon that reloads it at boot, so it's a one-time
step. The viewer keeps running as your user on 37701; only the kernel redirect touches port 80. On Windows,
normal users may bind port 80 when nothing else uses it, so `bash scripts/memlog.sh ui 80` is enough there.

Once the forward is installed, use the portless address and forget about `:37701`. A quirk of the loopback
redirect on macOS is that direct connections to the target port only succeed once, so the viewer treats port
80 as the canonical path: it prints only the portless URL, and a second `ui` start detects the running
instance through port 80 and reuses it instead of opening another port.

### HTTPS

Not provided. A local certificate needs a locally trusted CA, which every browser would have to be told
about; for a page that only ever listens on 127.0.0.1 it adds setup without adding safety. If you want it
anyway, Caddy does it in one line: `sudo caddy reverse-proxy --from codingagentmemory.local --to 127.0.0.1:37701`.

The viewer binds only to 127.0.0.1 in every option; nothing here exposes it to your network.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Nothing appears in the day log | hooks not loaded yet | start a new session; in Claude Code open `/hooks` once |
| Every line appears twice | plugin and hand-wired hooks both active | remove one of them |
| "keyword search is active" note never goes away | `setup.sh` not run, or it failed | run it and read its output; it prints the environment path |
| Viewer says the port is in use | another program on 37701 | it picks the next free port and prints it; or `memlog.sh ui 38000` |
| `jq: command not found` in hook output | `jq` missing | install it (see prerequisites) |
| Checkpoint never triggers | fewer than 5 logged changes since the last one | make more edits, or lower `MEMLOG_SUMMARY_EVERY` |
| Memory from a deleted project keeps appearing | index still has its rows | `memlog.sh prune` (dry run), then `prune --apply` |
