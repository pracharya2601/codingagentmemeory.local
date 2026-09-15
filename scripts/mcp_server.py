#!/usr/bin/env python3
"""mcp_server.py — local-memory as an MCP server (stdio). Zero dependencies.

Lets any MCP-capable agent (Codex, Gemini CLI, OpenCode, Cursor, Claude Code, …) read and write the same
memory the hooks use, without needing hooks at all:

  memory_context     one call at the start of a turn: where the project was left, entries relevant to the
                     task, and a pending checkpoint request if one is due
  memory_search      hybrid search (keywords + meaning) over this project's memory
  memory_last        the latest checkpoint entry
  memory_recent      newest entries, optionally by kind
  memory_checkpoint  write a checkpoint (session entry + typed observations) and index it
  memory_log_edit    record that a file was changed (for agents without tool hooks)
  memory_note        record the user's request for this turn

The project is the server's working directory (agents launch MCP servers in the project) or
MEMORY_PROJECT_DIR if set. Transport: newline-delimited JSON-RPC 2.0 on stdin/stdout (MCP stdio).
"""
import json, os, sys, subprocess
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
MEMLOG = os.path.join(HERE, "memlog.sh")
PROJECT = os.environ.get("MEMORY_PROJECT_DIR") or os.getcwd()
PROTOCOL = "2025-06-18"

def memlog(*args):
    r = subprocess.run(["bash", MEMLOG, *args], capture_output=True, text=True, timeout=120)
    return r.stdout.strip()

def cfg_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR", os.path.join(os.path.expanduser("~"), ".claude"))

def mem_dir():
    import re
    slug = re.sub(r"[^A-Za-z0-9-]", "-", PROJECT)
    return os.path.join(cfg_dir(), "projects", slug, "memory")

TOOLS = [
    {"name": "memory_context",
     "description": "Call this once at the start of a turn. Returns where this project was left, memory entries relevant to the given task, and — if enough changes have accumulated — a checkpoint request you must carry out before finishing.",
     "inputSchema": {"type": "object", "properties": {"task": {"type": "string", "description": "The user's request or what you are about to do"}}, "required": ["task"]}},
    {"name": "memory_search",
     "description": "Search this project's memory (past decisions, bugfixes, discoveries, sessions, user preferences). Hybrid keyword + semantic ranking.",
     "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}, "limit": {"type": "integer", "default": 8}}, "required": ["query"]}},
    {"name": "memory_last",
     "description": "The most recent checkpoint for this project: request, files, learned, completed, next steps.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "memory_recent",
     "description": "Newest memory entries for this project, optionally filtered by kind (decision, bugfix, feature, change, discovery, refactor, session, edit).",
     "inputSchema": {"type": "object", "properties": {"limit": {"type": "integer", "default": 15}, "kind": {"type": "string"}}}},
    {"name": "memory_checkpoint",
     "description": "Write a memory checkpoint: one session entry plus typed observations. Use the exact file list you changed. Each observation type is one of discovery, change, feature, bugfix, decision, refactor.",
     "inputSchema": {"type": "object", "properties": {
         "request": {"type": "string", "description": "One line: what was asked"},
         "files": {"type": "array", "items": {"type": "string"}},
         "learned": {"type": "string"}, "completed": {"type": "string"}, "next_steps": {"type": "string"},
         "observations": {"type": "array", "items": {"type": "object", "properties": {
             "type": {"type": "string", "enum": ["discovery", "change", "feature", "bugfix", "decision", "refactor"]},
             "title": {"type": "string"}, "facts": {"type": "string"}}, "required": ["type", "title", "facts"]}}},
      "required": ["request", "learned", "completed", "next_steps"]}},
    {"name": "memory_log_edit",
     "description": "Record that a file was created or modified in this project (only needed for agents whose tool calls are not hooked).",
     "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}},
    {"name": "memory_note",
     "description": "Record the user's request for this turn in the activity log.",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
]

def tool_call(name, a):
    a = a or {}
    if name == "memory_context":
        task = a.get("task", "")
        if task: memlog("note", PROJECT, task)
        parts = []
        last = memlog("last", PROJECT)
        if last: parts.append("Where this project was left:\n" + last)
        hits = memlog("retrieve", PROJECT, task, "6") if task else ""
        if hits: parts.append("Relevant past memory (verify against the repo before relying on it):\n" + hits)
        due = memlog("due", PROJECT)
        if due: parts.append("CHECKPOINT DUE — before you finish this turn, call memory_checkpoint with the fields described here:\n" + due)
        return "\n\n".join(parts) or "No memory for this project yet."
    if name == "memory_search":
        return memlog("retrieve", PROJECT, a["query"], str(a.get("limit", 8))) or "No matches."
    if name == "memory_last":
        return memlog("last", PROJECT) or "No checkpoint yet."
    if name == "memory_recent":
        sys.path.insert(0, HERE); import memindex as m, re
        con = m.db(); slug = re.sub(r"[^A-Za-z0-9-]", "-", PROJECT)
        w, args = ["project=?"], [slug]
        if a.get("kind"): w.append("kind=?"); args.append(a["kind"])
        rows = con.execute(f"SELECT id, project, ts, kind, title, body FROM entries WHERE {' AND '.join(w)} ORDER BY ts DESC, id DESC LIMIT ?",
                           args + [int(a.get("limit", 15))]).fetchall()
        return m.fmt(rows) if rows else "No entries."
    if name == "memory_checkpoint":
        d = mem_dir(); os.makedirs(d, exist_ok=True)
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        files = ", ".join(a.get("files") or []) or "none"
        sl = os.path.join(d, "session-log.md")
        if not os.path.exists(sl): open(sl, "w").write("# Session log\n")
        with open(sl, "a") as f:
            f.write(f"\n## {ts} — {a['request']}\n**Files:** {files}\n**Learned:** {a['learned']}\n**Completed:** {a['completed']}\n**Next steps:** {a['next_steps']}\n")
        obs = a.get("observations") or []
        if obs:
            ob = os.path.join(d, "observations.md")
            if not os.path.exists(ob): open(ob, "w").write("# Observations\n")
            with open(ob, "a") as f:
                f.write(f"\n## {ts}\n")
                for o in obs: f.write(f"- [{o['type']}] {o['title']} — {o['facts']}\n")
        memlog("sync", PROJECT)
        return f"Checkpoint written ({len(obs)} observations) and indexed."
    if name == "memory_log_edit":
        memlog("edit", PROJECT, a["path"], "Edit"); return "logged"
    if name == "memory_note":
        memlog("note", PROJECT, a["text"]); return "logged"
    raise KeyError(name)

def reply(id_, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id_}
    if error: msg["error"] = error
    else: msg["result"] = result
    sys.stdout.write(json.dumps(msg) + "\n"); sys.stdout.flush()

def main():
    for line in sys.stdin:
        line = line.strip()
        if not line: continue
        try: req = json.loads(line)
        except Exception: continue
        method, id_, params = req.get("method"), req.get("id"), req.get("params") or {}
        if method == "initialize":
            reply(id_, {"protocolVersion": params.get("protocolVersion", PROTOCOL), "capabilities": {"tools": {}},
                        "serverInfo": {"name": "local-memory", "version": "0.2.2"},
                        "instructions": "Call memory_context at the start of each turn with the user's request. If it reports a checkpoint due, call memory_checkpoint before finishing."})
        elif method == "notifications/initialized" or method.startswith("notifications/"):
            continue
        elif method == "ping":
            reply(id_, {})
        elif method == "tools/list":
            reply(id_, {"tools": TOOLS})
        elif method == "tools/call":
            try:
                text = tool_call(params.get("name"), params.get("arguments"))
                reply(id_, {"content": [{"type": "text", "text": text}], "isError": False})
            except Exception as e:
                reply(id_, {"content": [{"type": "text", "text": f"error: {e}"}], "isError": True})
        elif id_ is not None:
            reply(id_, error={"code": -32601, "message": f"method not found: {method}"})

if __name__ == "__main__":
    main()
