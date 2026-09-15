---
description: Remove a project from the memory index (and optionally its memory folder), or prune projects whose folder is gone
argument-hint: [<project path> | --prune] [--files]
allowed-tools: Bash(bash *memlog.sh projects*), Bash(bash *memlog.sh prune*), Bash(bash *memlog.sh forget*)
---

Manage what the memory index remembers. Arguments: `$ARGUMENTS`

1. If the arguments are empty, list what is indexed and stop:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memlog.sh" projects
   ```
2. If the arguments contain `--prune`, first show the dry run and ask the user to confirm before applying:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memlog.sh" prune
   ```
   Only after an explicit yes, run `prune --apply` (add `--files` only if the user included it).
3. Otherwise treat the first argument as a project path and ask for confirmation, then:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memlog.sh" forget "<path>" [--files]
   ```

Never run `--apply` or `--files` without the user confirming in this conversation. Deleting memory is irreversible.
