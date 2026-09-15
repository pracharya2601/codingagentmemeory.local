---
description: Open the memory viewer in the browser (timeline, filters, hybrid search); Ctrl-C in its terminal stops it
allowed-tools: Bash(nohup bash *memlog.sh ui*), Bash(bash *memlog.sh ui*)
---

Start the local memory viewer detached so it keeps running after this turn, then tell the user the URL.

```bash
mkdir -p "$HOME/.claude-memory" && nohup bash "${CLAUDE_PLUGIN_ROOT}/scripts/memlog.sh" ui > "$HOME/.claude-memory/viewer.log" 2>&1 &
sleep 1; head -1 "$HOME/.claude-memory/viewer.log"
```

Report the address printed (normally http://codingagentmemory.local:37701/, with http://127.0.0.1:37701/ as the fallback). Mention that `pkill -f memview.py` stops it. Do not open the page yourself unless the user asks.
