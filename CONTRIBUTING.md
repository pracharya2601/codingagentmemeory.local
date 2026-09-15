# Contributing

Thanks for looking. The most useful contributions right now, in order:

1. **Adapter verification reports.** Five adapters are written against published extension references but
   have not been run inside their tools yet (see `docs/ADAPTERS.md`). Try one, open an issue with the tool
   version and what happened. Fixes to event or field names are usually one line.
2. **New adapters.** Any agent with hooks or MCP can be supported. `docs/ADAPTERS.md` lists the four
   questions to answer. Keep the adapter thin and put logic in the core.
3. **Retrieval quality.** Better query term extraction, smarter fusion weights, a larger embedding model as an
   option. Measure before and after with real queries; `docs/ARCHITECTURE.md` has baseline numbers.

## Ground rules

- No background daemons, no cloud calls, no API keys. That's the point of the project.
- Everything must work with `python3` and `jq` alone; vectors stay optional.
- No absolute personal paths anywhere in the repo. `grep -rn "/Users/" .` should return only documentation
  placeholders.
- Destructive operations (`forget --files`, `prune --apply`) must never run without a confirmation step in
  the adapter or command that triggers them.
- Run `bash tests/run.sh` before opening a pull request and add a check for anything you change.

## Layout

```
scripts/     core: memlog.sh (operations), memindex.py (index), mcp_server.py, memview.py (viewer), setup.sh
hooks/       Claude Code plugin hooks
commands/    Claude Code slash commands
adapters/    one folder per tool, each with a README and its status
docs/        architecture, adapter matrix, testing
tests/       offline suite
```

## Style

Shell scripts are POSIX-ish bash and must run on macOS's BSD userland as well as GNU. Watch out for `sed -i`,
`stat`, and `sed N` differences; the core uses awk for joins for that reason. Python is stdlib only in the
core; `sqlite-vec` and `fastembed` are imported lazily and only when present.
