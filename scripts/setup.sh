#!/bin/bash
# setup.sh — optional one-time step that turns on semantic (vector) search.
# Creates ~/.claude-memory/venv with sqlite-vec + fastembed, downloads the bge-small model (~64 MB),
# and embeds everything already in the index. Without this, the plugin runs keyword (BM25) search only.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$HOME/.claude-memory"; VENV="$BASE/venv"
mkdir -p "$BASE"

if [ ! -x "$VENV/bin/python" ]; then
  echo "creating Python environment at $VENV"
  if command -v uv >/dev/null 2>&1; then
    uv venv "$VENV" --python 3.11 -q 2>/dev/null || uv venv "$VENV" -q
    uv pip install -q --python "$VENV/bin/python" sqlite-vec fastembed
  else
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --upgrade pip
    "$VENV/bin/pip" install -q sqlite-vec fastembed
  fi
fi

"$VENV/bin/python" - <<'EOF'
import sqlite3, sqlite_vec
c = sqlite3.connect(":memory:"); c.enable_load_extension(True); sqlite_vec.load(c)
print("sqlite-vec OK, sqlite", sqlite3.sqlite_version)
EOF

echo "downloading the embedding model (first run only) and embedding existing entries…"
"$VENV/bin/python" "$DIR/memindex.py" embed
"$VENV/bin/python" "$DIR/memindex.py" stats | tail -1
rm -f "$BASE/.setup-hint-shown"
echo "done. Semantic search is on. Prompt-time retrieval now uses hybrid ranking."
