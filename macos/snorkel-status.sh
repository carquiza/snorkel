#!/bin/bash
# One screen of Snorkel's state. No root needed.
set -u
CONF_DIR=/usr/local/etc/snorkel
LOG=/var/log/snorkel.log
DLOG=/var/log/snorkel-daemon.log
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/snorkel-lib.sh"
IFACE=feth0
[ -r "$CONF_DIR/snorkel.conf" ] && . "$CONF_DIR/snorkel.conf"
WIFI_DEV=$(builtin_wifi_dev)

yn() { [ -n "$1" ] && echo "$1" || echo "-"; }

echo "== Snorkel =="
if [ -d "$CONF_DIR" ]; then
  echo "installed:        yes ($CONF_DIR)"
else
  echo "installed:        no  (just install)"
fi
echo "daemon:           $(pgrep -f snorkel-run.sh >/dev/null && echo running || echo stopped)"
echo "sta_client:       $(yn "$(pgrep -x sta_client | head -1)")"
echo "mode:             $(cat "$CONF_DIR/mode" 2>/dev/null || echo auto)"
echo "built-in Wi-Fi:   $WIFI_DEV $(wifi_power "$WIFI_DEV")  $(ipconfig getifaddr "$WIFI_DEV" 2>/dev/null)"
echo "adapter $IFACE:    $(yn "$(ipconfig getifaddr "$IFACE" 2>/dev/null)")  router $(yn "$(dhcp_router "$IFACE")")"
echo "default route:    $(yn "$(default_route_if)")"
echo "internet via:     $(yn "$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')")"
echo "dns:              $(scutil --dns 2>/dev/null | awk '/nameserver\[0\]/{print $3; exit}')"
if [ -r "$LOG" ]; then
  echo
  echo "== link (last state, last link line) =="
  grep "station state:" "$LOG" | tail -1
  grep "block ack: TID" "$LOG" | tail -1
  grep "link:" "$LOG" | tail -1
fi
if [ -r "$DLOG" ]; then
  echo
  echo "== daemon (last 8 lines) =="
  tail -8 "$DLOG"
fi
