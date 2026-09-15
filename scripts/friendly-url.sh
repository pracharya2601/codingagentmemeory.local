#!/bin/bash
# friendly-url.sh — make the viewer reachable without a port number, e.g. http://codingagentmemory.local/
#
#   friendly-url.sh enable  [port]     forward port 80 -> viewer port (default 37701); asks for sudo once
#   friendly-url.sh disable            remove the forwarding rule
#   friendly-url.sh status
#   friendly-url.sh windows            print the steps for Windows (hosts file + WSL)
#
# The name itself needs no setup on macOS: the viewer publishes *.local names through Bonjour while it runs.
# On Linux it uses Avahi if installed. This script only handles the port, which needs root on every OS.
ACTION="${1:-status}"; PORT="${2:-37701}"; ANCHOR="com.local-memory"
OS=$(uname -s)

case "$OS:$ACTION" in
  Darwin:enable)
    echo "Forwarding 127.0.0.1:80 -> 127.0.0.1:$PORT with the packet filter (anchor $ANCHOR). Needs sudo."
    printf 'rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port %s\n' "$PORT" | sudo pfctl -a "$ANCHOR" -f - 2>/dev/null
    sudo pfctl -e 2>/dev/null; sudo pfctl -a "$ANCHOR" -s nat 2>/dev/null
    echo "Done. Start the viewer (bash memlog.sh ui) and open http://codingagentmemory.local/"
    echo "This rule lasts until reboot; run 'friendly-url.sh enable' again after restarting, or add it to a launchd job."
    ;;
  Darwin:disable)
    sudo pfctl -a "$ANCHOR" -F all 2>/dev/null && echo "forwarding removed"
    ;;
  Darwin:status)
    if sudo -n true 2>/dev/null; then sudo pfctl -a "$ANCHOR" -s nat 2>/dev/null || echo "no forwarding rule"; else echo "run with sudo to inspect: sudo pfctl -a $ANCHOR -s nat"; fi
    ;;
  Linux:enable)
    echo "Redirecting port 80 -> $PORT with iptables (needs sudo)."
    sudo iptables -t nat -A OUTPUT -o lo -p tcp --dport 80 -j REDIRECT --to-port "$PORT" && echo "Done. Open http://codingagentmemory.local/ (needs avahi-utils for the name, or a hosts line)."
    ;;
  Linux:disable)
    sudo iptables -t nat -D OUTPUT -o lo -p tcp --dport 80 -j REDIRECT --to-port "$PORT" && echo "redirect removed"
    ;;
  Linux:status)
    sudo iptables -t nat -L OUTPUT -n 2>/dev/null | grep -E "REDIRECT.*dpt:80" || echo "no redirect rule"
    ;;
  *:windows|Darwin:windows|Linux:windows)
    cat <<'EOF'
Windows (viewer running under WSL2 or Git Bash):
  1. Open Notepad as Administrator and add this line to C:\Windows\System32\drivers\etc\hosts
         127.0.0.1 codingagentmemory.local
     (Windows resolves .local through the hosts file first, so no Bonjour is needed.)
  2. Start the viewer:   bash scripts/memlog.sh ui
     Under WSL2, Windows forwards localhost ports automatically, so the browser on Windows reaches it.
  3. Open http://codingagentmemory.local:37701/
  4. To drop the port, run the viewer on 80 (Windows allows this for normal users when nothing else
     uses the port):   bash scripts/memlog.sh ui 80     then open http://codingagentmemory.local/
EOF
    ;;
  *)
    echo "unsupported: $OS $ACTION"; sed -n '2,10p' "$0"; exit 1 ;;
esac
