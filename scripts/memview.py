#!/usr/bin/env python3
"""memview.py — on-demand browser viewer for the memory index (no daemon: runs while you look, Ctrl-C stops it).

  memview.py [port] [names]   default port 37701, binds 127.0.0.1 only
  names: comma-separated friendly hostnames (default codingagentmemory.local, or MEMVIEW_NAME). On macOS
  each *.local name is published through Bonjour (dns-sd, no sudo); on Linux through Avahi if installed.
Routes: /  (single-page UI)
        /api/projects
        /api/kinds?project=
        /api/search?q=&project=&mode=hybrid|keyword|meaning&kind=&from=&to=&limit=
        /api/timeline?project=&kind=&from=&to=&q=&limit=&offset=
        /api/entry?id=
"""
import json, os, sys, threading, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import memindex as m

import platform, shutil, socket, subprocess, atexit, time
PORT = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 37701
# Friendly names: second argument or MEMVIEW_NAME (comma-separated). Published via Bonjour on macOS
# (dns-sd, no sudo) or Avahi on Linux; elsewhere a hosts-file line is suggested instead.
NAMES = [n.strip() for n in (sys.argv[2] if len(sys.argv) > 2 else os.environ.get("MEMVIEW_NAME", "codingagentmemory.local")).split(",") if n.strip()]
_lock = threading.Lock()
_publishers = []

def resolves(name, port, tries=1):
    for _ in range(tries):
        try:
            socket.getaddrinfo(name, port); return True
        except OSError:
            time.sleep(0.3)
    return False

def publish_names(port):
    """Make each friendly name resolve to 127.0.0.1 while the viewer runs. Returns [(name, how|None)]."""
    out = []
    for name in NAMES:
        how = None
        # on macOS publish straight away: a lookup for an unpublished .local name blocks ~5 s before failing
        if platform.system() == "Darwin" and shutil.which("dns-sd") and name.endswith(".local"):
            p = subprocess.Popen(["dns-sd", "-P", name.rsplit(".", 1)[0], "_http._tcp", "local", str(port), name, "127.0.0.1"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            _publishers.append(p); how = "bonjour"       # registration lands within ~1 s; not verified here because a
                                                         # lookup that misses blocks ~5 s and would delay startup
        elif resolves(name, port):
            how = "already resolves"                      # hosts file, or published by something else
        elif platform.system() == "Linux" and shutil.which("avahi-publish") and name.endswith(".local"):
            p = subprocess.Popen(["avahi-publish", "-a", "-R", name, "127.0.0.1"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            _publishers.append(p); how = "avahi" if resolves(name, port, tries=10) else None
        out.append((name, how))
    return out

def stop_publishers():
    for p in _publishers:
        try: p.terminate()
        except Exception: pass
atexit.register(stop_publishers)

def row(r):
    _id, project, ts, kind, title, body = r
    return {"id": _id, "project": project, "ts": ts, "kind": kind, "title": title, "body": m.clean_body(body)}

def api(path, q):
    con = m.db()   # one SQLite connection per request; SQLite serialises writers itself, no process-wide lock needed
    g = lambda k, d=None: (q.get(k) or [d])[0]
    if True:
        if path == "/api/projects":
            return [{"slug": s, "path": p, "entries": n, "exists": ex} for s, p, n, ex in m.project_rows(con)]
        if path == "/api/kinds":
            proj = g("project", "all")
            w, args = ("WHERE project=?", [proj]) if proj != "all" else ("", [])
            return [{"kind": k, "n": n} for k, n in con.execute(f"SELECT kind, count(*) FROM entries {w} GROUP BY 1 ORDER BY 2 DESC", args)]
        if path == "/api/search":
            text = g("q", "")
            if not text.strip(): return []
            flt = dict(kind=g("kind", "") or None, date_from=g("from", "") or None, date_to=g("to", "") or None)
            rows = m.query(con, g("project", "all"), text, int(g("limit", "40")), exclude=(), mode=g("mode", "hybrid"), **flt)
            return [row(r) for r in rows]
        if path == "/api/timeline":
            proj, kind, text = g("project", "all"), g("kind", ""), g("q", "")
            limit, offset = int(g("limit", "100")), int(g("offset", "0"))
            where, args = [], []
            if proj != "all": where.append("project=?"); args.append(proj)
            if kind: where.append("kind=?"); args.append(kind)
            if g("from"): where.append("ts >= ?"); args.append(g("from"))
            if g("to"): where.append("ts < ?"); args.append(g("to") + "~")
            if text.strip(): where.append("(title LIKE ? OR body LIKE ?)"); args += [f"%{text}%", f"%{text}%"]
            w = ("WHERE " + " AND ".join(where)) if where else ""
            rows = con.execute(f"SELECT id, project, ts, kind, title, body FROM entries {w} ORDER BY ts DESC, id DESC LIMIT ? OFFSET ?",
                               args + [limit, offset]).fetchall()
            total = con.execute(f"SELECT count(*) FROM entries {w}", args).fetchone()[0]
            return {"total": total, "rows": [row(r) for r in rows]}
        if path == "/api/entry":
            r = con.execute("SELECT id, project, ts, kind, title, body FROM entries WHERE id=?", (int(g("id", "0")),)).fetchone()
            return row(r) if r else None
    return {"error": "unknown route"}

PAGE = r"""<!doctype html><html><head><meta charset="utf-8"><title>Memory</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#fafaf8;--fg:#1c1c1a;--mut:#6b6b66;--line:#e4e2dc;--pan:#fff;--acc:#2f6fdb;--accfg:#fff;--chip:#eef1f6;--hl:#fff3c4;--warn:#c0392b}
@media(prefers-color-scheme:dark){:root{--bg:#141413;--fg:#ececea;--mut:#9a9a94;--line:#2c2c2a;--pan:#1c1c1b;--acc:#7aa7ff;--accfg:#101010;--chip:#26262a;--hl:#4a3f12;--warn:#ff7b6b}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}
.app{display:grid;grid-template-columns:270px 1fr;height:100vh}
aside{border-right:1px solid var(--line);overflow:auto;padding:12px;background:var(--pan)}
main{overflow:auto;padding:0 24px 24px}
h1{font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--mut);margin:6px 0 8px}
input,select,button{font:inherit;padding:8px 10px;border:1px solid var(--line);border-radius:8px;background:var(--pan);color:var(--fg)}
button{cursor:pointer}button.pri{background:var(--acc);color:var(--accfg);border-color:var(--acc);font-weight:600}
.proj{display:flex;justify-content:space-between;gap:8px;padding:6px 8px;border-radius:6px;cursor:pointer}
.proj:hover,.proj.on{background:var(--chip)}.proj.on{font-weight:600}.proj .n{color:var(--mut);font-variant-numeric:tabular-nums}
.proj.gone{opacity:.6}.proj.gone .name::after{content:" · folder gone";color:var(--warn);font-size:11px}
#pf{width:100%;margin-bottom:8px}
.top{position:sticky;top:0;background:var(--bg);padding:14px 0 10px;z-index:2;border-bottom:1px solid var(--line);margin-bottom:12px}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:8px}
#q{flex:1;min-width:260px;padding:10px 12px;font-size:15px}
.lbl{font-size:12px;color:var(--mut);text-transform:uppercase;letter-spacing:.06em;margin-right:2px}
.chips{display:flex;gap:6px;flex-wrap:wrap;align-items:center}.chip{padding:3px 9px;border-radius:999px;background:var(--chip);cursor:pointer;font-size:12px;border:1px solid transparent}
.chip.on{background:var(--acc);color:var(--accfg)}.chip.ghost{background:transparent;border-color:var(--line);color:var(--mut)}
.status{display:flex;justify-content:space-between;align-items:center;color:var(--mut);font-size:12px;margin:2px 0 10px}
.e{border:1px solid var(--line);border-radius:10px;background:var(--pan);padding:10px 14px;margin-bottom:8px;cursor:pointer}
.e:hover{border-color:var(--acc)}.e .h{display:flex;gap:10px;align-items:baseline;flex-wrap:wrap}
.e .t{font-weight:600}.e .k{font-size:11px;padding:1px 7px;border-radius:999px;background:var(--chip);color:var(--mut);white-space:nowrap}
.e .d,.e .p{color:var(--mut);font-size:12px;font-variant-numeric:tabular-nums}.e .p{margin-left:auto}
.e .s{margin-top:4px;color:var(--mut);font-size:13px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.e .b{display:none;margin-top:8px;white-space:pre-wrap;font-size:13px;line-height:1.55}
.e.open .s{display:none}.e.open .b{display:block}.e .b b{color:var(--acc)}mark{background:var(--hl);color:inherit;padding:0 1px;border-radius:2px}
.more{display:block;margin:12px auto}.empty{color:var(--mut);padding:40px;text-align:center;line-height:1.7}
kbd{font:11px monospace;padding:1px 5px;border:1px solid var(--line);border-radius:4px;background:var(--chip)}
@media(max-width:760px){.app{grid-template-columns:1fr}aside{max-height:30vh;border-right:0;border-bottom:1px solid var(--line)}}
</style></head><body><div class="app">
<aside><h1>Projects</h1><input id="pf" type="search" placeholder="filter projects…"><div id="projects"></div></aside>
<main>
 <div class="top">
  <div class="row">
   <input id="q" type="search" placeholder="Search memory… (press Enter)" autofocus>
   <select id="mode" title="How to rank results"><option value="hybrid">Hybrid: keywords + meaning</option><option value="keyword">Keywords only (BM25)</option><option value="meaning">Meaning only (vectors)</option></select>
   <button class="pri" id="go">Search</button><button id="clear">Clear</button>
  </div>
  <div class="row"><span class="lbl">Date</span>
   <input type="date" id="from" title="from"><span class="lbl">to</span><input type="date" id="to" title="to">
   <span class="chips" id="quick"><span class="chip ghost" data-d="1">today</span><span class="chip ghost" data-d="7">7 days</span><span class="chip ghost" data-d="30">30 days</span><span class="chip ghost" data-d="0">all time</span></span>
  </div>
  <div class="row"><span class="lbl">Kind</span><div class="chips" id="kinds"></div></div>
  <div class="status"><span id="count"></span><span id="hint"></span></div>
 </div>
 <div id="list"></div>
</main></div>
<script>
const $=s=>document.querySelector(s);const st={project:'all',kind:'',from:'',to:'',q:'',mode:'hybrid',offset:0,allKinds:false};
const esc=s=>(s||'').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
const j=u=>fetch(u).then(r=>r.json());
const rx=t=>t.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
const NOHL=new Set(['that','this','with','from','what','when','where','which','after','before','than','then','them','they','there','here','have','does','were','been','about','into','over','should','would','could','their','your']);
function fmt(b,q){let s=esc(b).replace(/\*\*(.+?)\*\*/g,'<b>$1</b>');if(q){for(const t of q.toLowerCase().split(/\s+/).filter(t=>t.length>3&&!NOHL.has(t)))s=s.replace(new RegExp('(^|[^a-z0-9])('+rx(t)+')','gi'),'$1<mark>$2</mark>')}return s}
const short=p=>p?p.replace(/^\/Users\/[^/]+\//,'~/'):'';const pname=s=>s.replace(/^-Users-[^-]+-/,'');
let PROJECTS=[];
function projects(){const f=($('#pf').value||'').toLowerCase();const tot=PROJECTS.reduce((a,p)=>a+p.entries,0);
 let h=`<div class="proj ${st.project=='all'?'on':''}" data-s="all"><span class="name">All projects</span><span class="n">${tot}</span></div>`;
 for(const p of PROJECTS){const name=short(p.path)||pname(p.slug);if(f&&!name.toLowerCase().includes(f))continue;
  h+=`<div class="proj ${p.exists===false?'gone':''} ${st.project==p.slug?'on':''}" data-s="${p.slug}" title="${p.slug}"><span class="name">${esc(name)}</span><span class="n">${p.entries}</span></div>`}
 $('#projects').innerHTML=h;document.querySelectorAll('.proj').forEach(el=>el.onclick=()=>{st.project=el.dataset.s;st.kind='';st.offset=0;projects();kinds();load()})}
async function kinds(){const ks=await j('/api/kinds?project='+encodeURIComponent(st.project));const shown=st.allKinds?ks:ks.slice(0,12);
 let h=`<span class="chip ${st.kind==''?'on':''}" data-k="">all</span>`+shown.map(k=>`<span class="chip ${st.kind==k.kind?'on':''}" data-k="${esc(k.kind)}">${esc(k.kind)} <span style="opacity:.6">${k.n}</span></span>`).join('');
 if(ks.length>12)h+=`<span class="chip ghost" id="morek">${st.allKinds?'fewer':'+'+(ks.length-12)+' more'}</span>`;
 $('#kinds').innerHTML=h;document.querySelectorAll('#kinds .chip[data-k]').forEach(el=>el.onclick=()=>{st.kind=el.dataset.k;st.offset=0;kinds();load()});
 const mk=$('#morek');if(mk)mk.onclick=()=>{st.allKinds=!st.allKinds;kinds()}}
function card(r){return `<div class="e" data-id="${r.id}"><div class="h"><span class="d">${esc(r.ts)}</span><span class="k">${esc(r.kind)}</span><span class="t">${fmt(r.title,st.q)}</span><span class="p">${esc(pname(r.project))}</span></div><div class="s">${fmt(r.body.slice(0,300),st.q)}</div><div class="b">${fmt(r.body,st.q)||'<i>(no body)</i>'}</div></div>`}
function render(rows,append){const h=rows.map(card).join('');
 if(append)$('#list').insertAdjacentHTML('beforeend',h);else $('#list').innerHTML=h||`<div class="empty">Nothing matches.<br>Try fewer filters, another project, or switch the ranking mode.</div>`;
 document.querySelectorAll('.e').forEach(el=>el.onclick=()=>el.classList.toggle('open'))}
function params(){return `project=${encodeURIComponent(st.project)}&kind=${encodeURIComponent(st.kind)}&from=${st.from}&to=${st.to}`}
async function load(append){document.querySelectorAll('.more').forEach(e=>e.remove());
 if(st.q.trim()){$('#count').textContent='searching…';const rows=await j(`/api/search?q=${encodeURIComponent(st.q)}&mode=${st.mode}&limit=50&${params()}`);
  $('#count').textContent=`${rows.length} hits for “${st.q}” · ranked by ${st.mode}`;$('#hint').textContent='click a card to expand';render(rows);return}
 const r=await j(`/api/timeline?limit=100&offset=${st.offset}&${params()}`);
 $('#count').textContent=`${r.total} entries · newest first`;$('#hint').textContent='type above and press Enter to search';render(r.rows,append);
 const shown=st.offset+r.rows.length;if(shown<r.total){const b=document.createElement('button');b.className='more';b.textContent=`Show more (${shown} of ${r.total})`;b.onclick=()=>{st.offset=shown;load(true)};$('#list').appendChild(b)}}
function search(){st.q=$('#q').value;st.mode=$('#mode').value;st.offset=0;load()}
$('#go').onclick=search;$('#q').onkeydown=e=>{if(e.key==='Enter')search()};$('#mode').onchange=()=>{if(st.q)search()};
$('#clear').onclick=()=>{$('#q').value='';st.q='';st.kind='';st.from='';st.to='';$('#from').value='';$('#to').value='';st.offset=0;kinds();load()};
$('#from').onchange=e=>{st.from=e.target.value;st.offset=0;load()};$('#to').onchange=e=>{st.to=e.target.value;st.offset=0;load()};
document.querySelectorAll('#quick .chip').forEach(el=>el.onclick=()=>{const d=+el.dataset.d;const iso=x=>x.toISOString().slice(0,10);
 if(d){const t=new Date();const f=new Date(t-(d-1)*864e5);st.from=iso(f);st.to=iso(t)}else{st.from='';st.to=''}
 $('#from').value=st.from;$('#to').value=st.to;st.offset=0;load()});
$('#pf').oninput=projects;
j('/api/projects').then(p=>{PROJECTS=p;projects()});kinds();load();
</script></body></html>"""

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urlparse(self.path); q = parse_qs(u.query)
        if u.path == "/":
            body = PAGE.encode(); ctype = "text/html; charset=utf-8"
        elif u.path.startswith("/api/"):
            try: body = json.dumps(api(u.path, q)).encode()
            except Exception as e: body = json.dumps({"error": str(e)}).encode()
            ctype = "application/json"
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store"); self.send_header("X-Local-Memory", "viewer"); self.end_headers(); self.wfile.write(body)

def ours(port, timeout=1.5, tries=1):
    """True if a local-memory viewer already answers on this port (identified by its response header)."""
    import urllib.request
    for _ in range(tries):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/projects", timeout=timeout) as r:
                return r.headers.get("X-Local-Memory") == "viewer"
        except Exception:
            time.sleep(0.3)
    return False

def portless_configured():
    """True if the port-80 forward from scripts/friendly-url.sh is installed (checked on disk, no network round trip)."""
    if os.environ.get("MEMVIEW_PORTLESS") == "1": return True
    return os.path.exists("/etc/pf.anchors/com.local-memory")   # macOS; Linux/Windows users set MEMVIEW_PORTLESS=1

def friendly_urls(port):
    """[(url, how)] for every name that resolves; portless when the port-80 forward is configured."""
    portless = port == 80 or portless_configured()
    out = []
    for name, how in publish_names(port):
        if how:
            out.append((f"http://{name}/" if portless else f"http://{name}:{port}/", how))
        else:
            print(f"note: {name} does not resolve here; add '127.0.0.1 {name}' to your hosts file to use it", file=sys.stderr)
    return out

if __name__ == "__main__":
    # Single instance: if a viewer already answers, reuse it instead of taking another port.
    # With the port-80 forward installed, probe through port 80: the pf loopback redirect makes direct
    # connections to the target port unreliable (only the first one succeeds), so port 80 is the canonical path.
    portless = portless_configured()
    if ours(80) if portless else ours(PORT):   # a refused connection returns instantly; a live viewer answers in ms
        name = next((n for n in NAMES if n.endswith(".local")), None)
        url = (f"http://{name}/" if portless else f"http://{name}:{PORT}/") if name and resolves(name, PORT) else (f"http://127.0.0.1/" if portless else f"http://127.0.0.1:{PORT}/")
        print(f"memory viewer already running at {url}", flush=True)
        webbrowser.open(url); sys.exit(0)
    srv = None
    for port in range(PORT, PORT + 20):   # port held by something else: take the next free one
        try:
            srv = ThreadingHTTPServer(("127.0.0.1", port), H); break
        except OSError:
            print(f"port {port} is in use by another program; trying {port + 1}", file=sys.stderr)
    if srv is None:
        sys.exit(f"could not bind any port in {PORT}..{PORT + 19}")
    # serve immediately (so a concurrent start can detect us), then publish names and announce
    t = threading.Thread(target=srv.serve_forever, daemon=True); t.start()
    url = "http://127.0.0.1/" if (portless and port == PORT) else f"http://127.0.0.1:{port}/"
    open_url = url
    for friendly, how in friendly_urls(port):
        print(f"memory viewer at {friendly}  ({how})")
        if open_url == url: open_url = friendly
    print(f"memory viewer at {url}  (Ctrl-C to stop)", flush=True)
    threading.Timer(1.5, lambda: webbrowser.open(open_url)).start()
    try: t.join()
    except KeyboardInterrupt: srv.shutdown()
    finally: srv.server_close()
