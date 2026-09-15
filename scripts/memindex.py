#!/usr/bin/env python3
"""memindex.py — SQLite full-text + vector index behind Claude Code's built-in memory folders.

One file, no daemon: ~/.claude-memory/index.db
  entries      : rows (project, ts, kind, title, body)
  entries_fts  : FTS5 full-text index (BM25)
  entries_vec  : sqlite-vec table of 384-dim embeddings (BAAI/bge-small-en-v1.5 via fastembed, local)
Query = hybrid: BM25 top-N and vector top-N merged with reciprocal rank fusion.
Vectors are optional: if sqlite-vec / fastembed are missing (or MEMINDEX_NOVEC=1) it falls back to BM25 only.

  memindex.py add    <project-slug> <kind> <title> <body>
  memindex.py query  <project-slug|all> <text> [limit]
  memindex.py sync   <project-slug> <session-log.md>      # index new '## ' sections
  memindex.py last   <project-slug>                        # latest session entry
  memindex.py embed  [batch-limit]                         # backfill vectors for rows without one
  memindex.py seed   <claude-mem.db>                       # import a claude-mem backup
  memindex.py stats
"""
import hashlib, os, re, sqlite3, sys, json
from datetime import datetime

HOME = os.path.expanduser("~")
BASE = os.path.join(HOME, ".claude-memory")
DB = os.environ.get("MEMINDEX_DB", os.path.join(BASE, "index.db"))
MODELS = os.path.join(BASE, "models")
MODEL_NAME = "BAAI/bge-small-en-v1.5"
DIM = 384
PROJ = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR", os.path.join(HOME, ".claude")), "projects")
NOVEC = os.environ.get("MEMINDEX_NOVEC") == "1"

STOP = set("""a an the and or but if then else for to of in on at by with from as is are was were be been being
this that these those it its i me my we our you your he she they them their what which who whom when where why how
can could should would will shall may might must do does did done have has had not no yes so than too very just
also about into over under again further here there all any both each few more most other some such only own same
please make want need let us get got go going use using used add fix update change check look see try run file files code""".split())

# ---------- vector support (optional) ----------
_vec_ok = None
def vec_available():
    global _vec_ok
    if _vec_ok is None:
        if NOVEC:
            _vec_ok = False
        else:
            try:
                import sqlite_vec  # noqa
                _vec_ok = True
            except Exception:
                _vec_ok = False
    return _vec_ok

_model = None
def model():
    global _model
    if _model is None:
        from fastembed import TextEmbedding
        _model = TextEmbedding(MODEL_NAME, cache_dir=MODELS)
    return _model

def embed(texts):
    return [list(map(float, v)) for v in model().embed(texts, batch_size=64)]

def ser(v):
    import sqlite_vec
    return sqlite_vec.serialize_float32(v)

# ---------- db ----------
def db():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    con = sqlite3.connect(DB)
    if vec_available():
        import sqlite_vec
        con.enable_load_extension(True); sqlite_vec.load(con); con.enable_load_extension(False)
    con.executescript("""
    CREATE TABLE IF NOT EXISTS entries(
      id INTEGER PRIMARY KEY, project TEXT NOT NULL, ts TEXT NOT NULL, kind TEXT NOT NULL,
      title TEXT, body TEXT, hash TEXT UNIQUE);
    CREATE INDEX IF NOT EXISTS ix_entries_project_ts ON entries(project, ts);
    CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
      title, body, content='entries', content_rowid='id', tokenize='porter unicode61');
    CREATE TRIGGER IF NOT EXISTS entries_ai AFTER INSERT ON entries BEGIN
      INSERT INTO entries_fts(rowid, title, body) VALUES (new.id, new.title, new.body); END;
    CREATE TRIGGER IF NOT EXISTS entries_ad AFTER DELETE ON entries BEGIN
      INSERT INTO entries_fts(entries_fts, rowid, title, body) VALUES('delete', old.id, old.title, old.body); END;
    """)
    if vec_available():
        con.execute(f"CREATE VIRTUAL TABLE IF NOT EXISTS entries_vec USING vec0(embedding float[{DIM}])")
        con.execute("CREATE TABLE IF NOT EXISTS vec_done(id INTEGER PRIMARY KEY)")
    # slug -> real path, so a project can be found (and forgotten) after its folder is deleted
    con.execute("CREATE TABLE IF NOT EXISTS projects(slug TEXT PRIMARY KEY, path TEXT, last_seen TEXT)")
    return con

def slug_of(path):
    return re.sub(r"[^A-Za-z0-9-]", "-", os.path.abspath(os.path.expanduser(path)))

def touch_project(con, slug, path=None):
    if path:
        con.execute("INSERT INTO projects(slug, path, last_seen) VALUES(?,?,?) ON CONFLICT(slug) DO UPDATE SET path=excluded.path, last_seen=excluded.last_seen",
                    (slug, path, datetime.now().strftime("%Y-%m-%d %H:%M")))

def project_rows(con):
    """[(slug, path|None, entries, exists|None)] for every project in the index."""
    paths = dict(con.execute("SELECT slug, path FROM projects"))
    out = []
    for slug, n in con.execute("SELECT project, count(*) FROM entries GROUP BY 1 ORDER BY 2 DESC"):
        p = paths.get(slug)
        out.append((slug, p, n, os.path.isdir(p) if p else None))
    return out

def forget(con, slug, files=False):
    """Delete every index row (and vector) for a project; optionally its Markdown memory folder too."""
    ids = [r[0] for r in con.execute("SELECT id FROM entries WHERE project=?", (slug,))]
    for rid in ids: remove(con, rid)
    con.execute("DELETE FROM projects WHERE slug=?", (slug,))
    removed_dir = None
    if files:
        import shutil
        d = os.path.join(PROJ, slug, "memory")
        if os.path.isdir(d):
            shutil.rmtree(d); removed_dir = d
    return len(ids), removed_dir

def h(*parts):
    return hashlib.sha1("\x1f".join(str(p) for p in parts).encode()).hexdigest()

def add(con, project, kind, title, body, ts=None, key=None):
    ts = ts or datetime.now().strftime("%Y-%m-%d %H:%M")
    key = key or h(project, kind, title, body, ts[:16])
    try:
        con.execute("INSERT INTO entries(project, ts, kind, title, body, hash) VALUES(?,?,?,?,?,?)",
                    (project, ts, kind, title or "", body or "", key))
        return True
    except sqlite3.IntegrityError:
        return False

_HASH_PREFIX = re.compile(r"^[0-9a-f]{40}\n")
def clean_body(body):
    return _HASH_PREFIX.sub("", body or "", count=1)

def doc_text(title, body):
    return ((title or "") + ". " + clean_body(body))[:1200]

def embed_pending(con, limit=None):
    """Embed rows that have no vector yet. Returns count."""
    if not vec_available(): return 0
    sql = "SELECT id, title, body FROM entries WHERE id NOT IN (SELECT id FROM vec_done) ORDER BY id"
    if limit: sql += f" LIMIT {int(limit)}"
    rows = con.execute(sql).fetchall()
    if not rows: return 0
    n = 0
    for i in range(0, len(rows), 256):
        chunk = rows[i:i+256]
        vecs = embed([doc_text(t, b) for _, t, b in chunk])
        for (rid, _, _), v in zip(chunk, vecs):
            con.execute("INSERT OR REPLACE INTO entries_vec(rowid, embedding) VALUES (?, ?)", (rid, ser(v)))
            con.execute("INSERT OR IGNORE INTO vec_done(id) VALUES (?)", (rid,))
            n += 1
        con.commit()
    return n

def terms(text, n=12):
    toks = re.findall(r"[a-z0-9][a-z0-9_./-]{2,}", text.lower())
    out, seen = [], set()
    for t in toks:
        t = t.strip("./-")
        if len(t) < 3 or t in STOP or t in seen: continue
        seen.add(t); out.append(t)
        if len(out) >= n: break
    return out

def _filters(project, exclude, kind=None, date_from=None, date_to=None):
    where, args = [], []
    if project != "all":
        where.append("e.project = ?"); args.append(project)
    if exclude:
        where.append("e.kind NOT IN (%s)" % ",".join("?" * len(exclude))); args += list(exclude)
    if kind:
        where.append("e.kind = ?"); args.append(kind)
    if date_from:
        where.append("e.ts >= ?"); args.append(date_from)
    if date_to:
        where.append("e.ts < ?"); args.append(date_to + "~")   # inclusive day: '2026-09-15~' sorts after '2026-09-15 23:59'
    return (" AND " + " AND ".join(where)) if where else "", args

def fts_search(con, project, text, k, exclude, **flt):
    ts = terms(text)
    if not ts: return []
    q = " OR ".join('"' + t.replace('"', '') + '"' for t in ts)
    f, fargs = _filters(project, exclude, **flt)
    return [r[0] for r in con.execute(
        f"""SELECT e.id FROM entries_fts JOIN entries e ON e.id = entries_fts.rowid
            WHERE entries_fts MATCH ? {f} ORDER BY bm25(entries_fts) LIMIT ?""", [q] + fargs + [k])]

def vec_search(con, project, text, k, exclude, **flt):
    if not vec_available(): return []
    try:
        qv = embed([text])[0]
    except Exception:
        return []
    f, fargs = _filters(project, exclude, **flt)
    # over-fetch from the vector table, then apply project/kind/date filters
    rows = con.execute(
        f"""SELECT v.rowid FROM (SELECT rowid, distance FROM entries_vec WHERE embedding MATCH ? ORDER BY distance LIMIT ?) v
            JOIN entries e ON e.id = v.rowid WHERE 1=1 {f} ORDER BY v.distance LIMIT ?""",
        [ser(qv), max(k * 8, 200)] + fargs + [k]).fetchall()
    return [r[0] for r in rows]

def query(con, project, text, limit=5, exclude=("prompt",), mode="hybrid", **flt):
    """mode: hybrid (BM25 + vectors fused), keyword (BM25 only), meaning (vectors only).
    flt: kind=, date_from='YYYY-MM-DD', date_to='YYYY-MM-DD'."""
    k = max(limit * 4, 20)
    fts = fts_search(con, project, text, k, exclude, **flt) if mode in ("hybrid", "keyword") else []
    vec = vec_search(con, project, text, k, exclude, **flt) if mode in ("hybrid", "meaning") else []
    score = {}
    for rank, rid in enumerate(fts): score[rid] = score.get(rid, 0) + 1.0 / (60 + rank)
    for rank, rid in enumerate(vec): score[rid] = score.get(rid, 0) + 1.0 / (60 + rank)
    ids = [rid for rid, _ in sorted(score.items(), key=lambda x: -x[1])[:limit]]
    if not ids: return []
    rows = {r[0]: r for r in con.execute(
        "SELECT id, project, ts, kind, title, body FROM entries WHERE id IN (%s)" % ",".join("?" * len(ids)), ids)}
    return [rows[i] for i in ids if i in rows]

def fmt(rows, body_chars=320):
    out = []
    for _id, project, ts, kind, title, body in rows:
        b = re.sub(r"\s+", " ", clean_body(body)).strip()
        if len(b) > body_chars: b = b[:body_chars].rsplit(" ", 1)[0] + " …"
        out.append(f"- [{ts[:10]} {kind}] {title}" + (f"\n  {b}" if b else ""))
    return "\n".join(out)

def sync_sessionlog(con, project, path):
    if not os.path.exists(path): return 0
    text = open(path, encoding="utf-8", errors="replace").read()
    n = 0
    for sec in re.split(r"(?m)^(?=## )", text):
        if not sec.startswith("## "): continue
        head, _, rest = sec.partition("\n")
        title = head[3:].strip()
        m = re.match(r"(\d{4}-\d{2}-\d{2})(?:\s+(\d{2}:\d{2}))?", title)
        ts = (m.group(1) + " " + (m.group(2) or "00:00")) if m else datetime.now().strftime("%Y-%m-%d %H:%M")
        if add(con, project, "session", title, rest.strip(), ts=ts, key=h("sessionlog", project, sec.strip())): n += 1
    return n

OBS_TYPES = ("discovery", "change", "feature", "bugfix", "decision", "refactor")

def sync_observations(con, project, path):
    """Index typed observations the session appends to observations.md at each checkpoint.
    Format:  ## 2026-09-15 11:30
             - [decision] Title — facts; more facts
    Each line becomes one row with kind = the bracketed type (one of OBS_TYPES). Deduplicated by content."""
    if not os.path.exists(path): return 0
    text = open(path, encoding="utf-8", errors="replace").read()
    n, ts = 0, datetime.now().strftime("%Y-%m-%d %H:%M")
    for line in text.splitlines():
        mh = re.match(r"^##\s+(\d{4}-\d{2}-\d{2})(?:\s+(\d{2}:\d{2}))?", line)
        if mh:
            ts = mh.group(1) + " " + (mh.group(2) or "00:00"); continue
        mo = re.match(r"^-\s*\[(\w+)\]\s*(.+)$", line)
        if not mo: continue
        kind = mo.group(1).lower()
        if kind not in OBS_TYPES: kind = "observation"
        rest = mo.group(2).strip()
        title, sep, body = rest.partition(" — ")
        if not sep: title, sep, body = rest.partition(": ")
        if add(con, project, kind, title.strip(), body.strip(), ts=ts, key=h("obs", project, ts, line.strip())): n += 1
    return n

def remove(con, rid):
    con.execute("DELETE FROM entries WHERE id=?", (rid,))
    if vec_available():
        con.execute("DELETE FROM entries_vec WHERE rowid=?", (rid,))
        con.execute("DELETE FROM vec_done WHERE id=?", (rid,))

def parse_md(text):
    """Return (frontmatter dict, body) for a memory file; tolerant of missing frontmatter."""
    fm = {}
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            for line in text[3:end].splitlines():
                m = re.match(r"\s*(\w+):\s*(.*)", line)
                if m: fm[m.group(1)] = m.group(2).strip().strip('"')
            text = text[end + 4:]
    return fm, text.strip()

def sync_md(con, project, memdir):
    """Index the hand-written memory files in a project's memory dir (kind='memory').
    One row per file, keyed by filename; re-indexed when the content changes. Skips the index file,
    the session log (synced separately), day logs, and the bulky cmem-* archives (already indexed row by row)."""
    if not os.path.isdir(memdir): return 0
    n = 0
    for fn in sorted(os.listdir(memdir)):
        if not fn.endswith(".md") or fn in ("MEMORY.md", "session-log.md", "observations.md") or fn.startswith("cmem-"): continue
        path = os.path.join(memdir, fn)
        text = open(path, encoding="utf-8", errors="replace").read()
        fm, body = parse_md(text)
        key = h("md", project, fn)
        content_hash = h(text)
        row = con.execute("SELECT id, body FROM entries WHERE hash=?", (key,)).fetchone()
        if row and row[1].startswith(content_hash): continue  # unchanged
        if row: remove(con, row[0])
        title = fm.get("description") or fm.get("name") or fn[:-3]
        kind = "memory:" + fm.get("type", "note") if fm.get("type") else "memory"
        ts = (fm.get("modified") or datetime.fromtimestamp(os.path.getmtime(path)).isoformat())[:16].replace("T", " ")
        # body is prefixed with the content hash so change detection needs no extra column
        add(con, project, kind, title, content_hash + "\n" + f"[{fn}] " + body[:4000], ts=ts, key=key); n += 1
    return n

def sync_all_md(con):
    total = 0
    for slug in os.listdir(PROJ):
        memdir = os.path.join(PROJ, slug, "memory")
        if os.path.isdir(memdir): total += sync_md(con, slug, memdir)
    return total

def last(con, project):
    return con.execute("SELECT ts, title, body FROM entries WHERE project=? AND kind='session' ORDER BY ts DESC, id DESC LIMIT 1",
                       (project,)).fetchone()

def resolve_slug(name, override):
    if name in override: return override[name]
    cands = [d for d in os.listdir(PROJ) if d.endswith("-" + name) and os.path.isdir(os.path.join(PROJ, d))]
    return sorted(cands, key=len)[0] if cands else None

def seed(con, src_path):
    src = sqlite3.connect(src_path); src.row_factory = sqlite3.Row
    # optional: {"claude-mem project name": "project slug"} for names that cannot be resolved automatically
    override = json.loads(os.environ.get("MEMINDEX_SEED_OVERRIDES", "{}"))
    def jl(s):
        try:
            v = json.loads(s) if s else []
            return v if isinstance(v, list) else [str(v)]
        except Exception:
            return [s] if s else []
    slugs, n_obs, n_sum = {}, 0, 0
    for r in src.execute("SELECT * FROM observations ORDER BY created_at_epoch"):
        slug = slugs.setdefault(r["project"], resolve_slug(r["project"], override))
        if not slug: continue
        body = " ".join(filter(None, [r["subtitle"], " ".join(jl(r["facts"])), r["narrative"],
                                       ("files: " + ", ".join(jl(r["files_modified"]))) if r["files_modified"] not in (None, "[]") else ""]))
        ts = (r["created_at"] or "")[:16].replace("T", " ")
        if add(con, slug, r["type"] or "observation", r["title"] or "", body, ts=ts, key=h("cmem-obs", r["id"])): n_obs += 1
    for r in src.execute("SELECT * FROM session_summaries ORDER BY created_at_epoch"):
        slug = slugs.setdefault(r["project"], resolve_slug(r["project"], override))
        if not slug: continue
        body = "\n".join(f"**{k.replace('_',' ').title()}:** {r[k]}" for k in ("learned", "completed", "next_steps", "notes") if r[k])
        ts = (r["created_at"] or "")[:16].replace("T", " ")
        if add(con, slug, "session", f"{ts[:10]} — {r['request'] or ''}", body, ts=ts, key=h("cmem-sum", r["id"])): n_sum += 1
    return n_obs, n_sum, slugs

def main(argv):
    if not argv: print(__doc__); return 1
    cmd, args = argv[0], argv[1:]
    con = db()
    with con:
        if cmd == "add":
            project, kind, title, body = args[0], args[1], args[2], args[3] if len(args) > 3 else ""
            print("added" if add(con, project, kind, title, body) else "dup")
        elif cmd == "query":
            project, text = args[0], args[1]
            limit = int(args[2]) if len(args) > 2 else 5
            rows = query(con, project, text, limit)
            if rows: print(fmt(rows))
        elif cmd == "sync":
            print(sync_sessionlog(con, args[0], args[1]))
        elif cmd == "syncmd":
            print(sync_md(con, args[0], args[1]))
        elif cmd == "syncobs":
            print(sync_observations(con, args[0], args[1]))
        elif cmd == "syncall":
            print("memory files indexed/updated:", sync_all_md(con))
        elif cmd == "last":
            r = last(con, args[0])
            if r: print(f"## {r[1]}\n{r[2]}")
        elif cmd == "embed":
            print("embedded", embed_pending(con, args[0] if args else None))
        elif cmd == "touch":
            touch_project(con, args[0], args[1]); print("ok")
        elif cmd == "projects":
            for slug, path, n, exists in project_rows(con):
                state = "unknown path" if exists is None else ("ok" if exists else "FOLDER MISSING")
                print(f"{n:6d}  {state:14s} {path or slug}")
        elif cmd == "forget":
            target = args[0]; files = "--files" in args
            slug = target if target.startswith("-") and "/" not in target else slug_of(target)
            n, d = forget(con, slug, files=files)
            print(f"forgot {n} entries for {slug}" + (f"; removed {d}" if d else ""))
        elif cmd == "prune":
            apply = "--apply" in args; files = "--files" in args
            gone = [(s, p, n) for s, p, n, ex in project_rows(con) if ex is False]
            if not gone: print("nothing to prune: every known project folder still exists")
            for s, p, n in gone:
                if apply:
                    cnt, d = forget(con, s, files=files)
                    print(f"pruned {cnt} entries for {p}" + (f"; removed {d}" if d else ""))
                else:
                    print(f"would prune {n} entries for {p}  (run with --apply; add --files to also delete its memory folder)")
        elif cmd == "seed":
            n_obs, n_sum, slugs = seed(con, args[0])
            print(f"seeded {n_obs} observations, {n_sum} session summaries")
            for k, v in slugs.items(): print(f"  {k} -> {v}")
        elif cmd == "stats":
            for row in con.execute("SELECT project, kind, count(*) FROM entries GROUP BY 1,2 ORDER BY 1,3 DESC"):
                print(*row, sep=" | ")
            total = con.execute("SELECT count(*) FROM entries").fetchone()[0]
            vecs = con.execute("SELECT count(*) FROM vec_done").fetchone()[0] if vec_available() else 0
            print(f"total: {total} | vectors: {vecs} | vector search: {'on' if vec_available() else 'off'}")
        else:
            print(__doc__); return 1
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
