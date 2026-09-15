#!/bin/bash
# friendly-url.sh — make the viewer reachable without a port number: http://codingagentmemory.local/
#
#   friendly-url.sh install [port]     macOS: forward 80 -> viewer port now AND at every boot (one sudo prompt)
#   friendly-url.sh enable  [port]     forward 80 -> viewer port until reboot (macOS pf / Linux iptables)
#   friendly-url.sh disable            remove the forwarding (and the boot job if installed)
#   friendly-url.sh status
#   friendly-url.sh windows            print the steps for Windows (hosts file + WSL)
#
# The name itself needs no setup on macOS: the viewer publishes *.local names through Bonjour while it runs.
# On Linux it uses Avahi if installed. This script only handles port 80, which needs root on macOS and Linux.
#
# macOS detail: pf only evaluates an anchor that the main ruleset references. So instead of loading the rule
# into a loose anchor, we build a ruleset = the system's /etc/pf.conf + a reference to our anchor, and load
# that. /etc/pf.conf itself is never modified.
set -u
ACTION="${1:-status}"; PORT="${2:-37701}"; ANCHOR="com.local-memory"
OS=$(uname -s)
RULE="rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port $PORT"
ANCHOR_FILE="/etc/pf.anchors/$ANCHOR"
CONF="/etc/pf.anchors/$ANCHOR.pf.conf"
PLIST="/Library/LaunchDaemons/$ANCHOR.pf.plist"

mac_write_files() {
  printf '%s\n' "$RULE" | sudo tee "$ANCHOR_FILE" >/dev/null
  # system ruleset + our rdr-anchor (translation rules must precede filter rules) + load line
  sudo awk -v a="$ANCHOR" -v f="$ANCHOR_FILE" '
    { print }
    /^rdr-anchor "com.apple\/\*"/ { print "rdr-anchor \"" a "\"" }
    END { print "load anchor \"" a "\" from \"" f "\"" }
  ' /etc/pf.conf | sudo tee "$CONF" >/dev/null
  grep -q "rdr-anchor \"$ANCHOR\"" "$CONF" || { printf 'rdr-anchor "%s"\n' "$ANCHOR" | sudo tee -a "$CONF" >/dev/null; }
  sudo chown root:wheel "$ANCHOR_FILE" "$CONF"; sudo chmod 644 "$ANCHOR_FILE" "$CONF"
}

mac_load() {
  sudo pfctl -q -f "$CONF" 2>/dev/null; sudo pfctl -q -e 2>/dev/null
  if sudo pfctl -a "$ANCHOR" -s nat 2>/dev/null | grep -q "port = 80"; then
    echo "forwarding 127.0.0.1:80 -> 127.0.0.1:$PORT is active"
  else
    echo "WARNING: rule did not load; run: sudo pfctl -a $ANCHOR -s nat" >&2; return 1
  fi
}

case "$OS:$ACTION" in
  Darwin:enable)
    echo "Needs sudo once."; mac_write_files && mac_load
    echo "Open http://codingagentmemory.local/ while the viewer runs. Lasts until reboot; use 'install' to make it permanent."
    ;;
  Darwin:install)
    echo "Needs sudo once. Writes a pf anchor + ruleset under /etc/pf.anchors and a LaunchDaemon that loads it at boot."
    mac_write_files
    sudo tee "$PLIST" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$ANCHOR.pf</string>
  <key>ProgramArguments</key><array>
    <string>/bin/sh</string><string>-c</string>
    <string>/sbin/pfctl -q -f $CONF; /sbin/pfctl -q -e</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
    sudo chown root:wheel "$PLIST"; sudo chmod 644 "$PLIST"
    sudo launchctl bootout system "$PLIST" 2>/dev/null; sudo launchctl bootstrap system "$PLIST" 2>/dev/null
    mac_load && echo "Installed. Survives reboots. Remove with: bash $0 disable"
    ;;
  Darwin:disable)
    sudo pfctl -q -f /etc/pf.conf 2>/dev/null && echo "system ruleset restored (forwarding removed)"
    if [ -f "$PLIST" ]; then sudo launchctl bootout system "$PLIST" 2>/dev/null; sudo rm -f "$PLIST"; echo "boot job removed"; fi
    sudo rm -f "$ANCHOR_FILE" "$CONF"
    ;;
  Darwin:status)
    [ -f "$PLIST" ] && echo "boot job: installed ($PLIST)" || echo "boot job: not installed"
    if sudo -n true 2>/dev/null; then sudo pfctl -a "$ANCHOR" -s nat 2>/dev/null || echo "no active forwarding rule"
    else echo "active rule: run 'sudo pfctl -a $ANCHOR -s nat' to check"; fi
    ;;
  Linux:enable|Linux:install)
    echo "Redirecting port 80 -> $PORT with iptables (needs sudo)."
    sudo iptables -t nat -A OUTPUT -o lo -p tcp --dport 80 -j REDIRECT --to-port "$PORT" && echo "Done. Open http://codingagentmemory.local/ (needs avahi-utils for the name, or a hosts line)."
    [ "$ACTION" = install ] && echo "To persist across reboots, save the rule with your distro's iptables-persistent / nftables tooling."
    ;;
  Linux:disable)
    sudo iptables -t nat -D OUTPUT -o lo -p tcp --dport 80 -j REDIRECT --to-port "$PORT" && echo "redirect removed"
    ;;
  Linux:status)
    sudo iptables -t nat -L OUTPUT -n 2>/dev/null | grep -E "REDIRECT.*dpt:80" || echo "no redirect rule"
    ;;
  *:windows)
    cat <<'EOF'
Windows (viewer running under WSL2 or Git Bash):
  1. Open Notepad as Administrator and add this line to C:\Windows\System32\drivers\etc\hosts
         127.0.0.1 codingagentmemory.local
     (Windows resolves .local through the hosts file first, so no Bonjour is needed.)
  2. Start the viewer on port 80 (allowed for normal users when nothing else uses it):
         bash scripts/memlog.sh ui 80
     Under WSL2, Windows forwards localhost ports automatically, so the Windows browser reaches it.
  3. Open http://codingagentmemory.local/
EOF
    ;;
  *)
    echo "unsupported: $OS $ACTION"; sed -n '2,11p' "$0"; exit 1 ;;
esac
