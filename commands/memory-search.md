---
description: "Search this project's memory index (hybrid keyword + meaning) and summarize what's relevant"
argument-hint: "<what you're looking for>"
allowed-tools: "Bash(bash *memlog.sh search*)"
---

Search the local memory index for the current project and report what's relevant.

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memlog.sh" search "$ARGUMENTS" 10
```

Then answer the user from the results: which entries matter, what they say, and how confident you are. Quote dates and kinds. If nothing useful comes back, say so plainly and suggest a different phrasing. Verify anything you plan to act on against the repository first; the index is a memory, not the source of truth.
