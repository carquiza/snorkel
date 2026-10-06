#!/bin/bash
# Set how the devourer station daemon uses the built-in Wi-Fi. Run with sudo.
#
#   devourer-sta-mode.sh adapter   built-in Wi-Fi off, the adapter carries everything
#   devourer-sta-mode.sh auto      built-in Wi-Fi on, internet via the adapter (default)
#   devourer-sta-mode.sh builtin   built-in Wi-Fi on and carrying everything
#
# The daemon applies the mode within 5 s. "adapter" is refused unless the
# adapter is joined, has an address and reaches both the router and the
# internet right now, because a headless Mac whose only working Wi-Fi was just
# switched off is unreachable. Once it is on, the daemon turns the built-in
# Wi-Fi back on by itself if the adapter link is down for 30 s, or if there is
# no internet for 30 s (then it also falls back to "auto").
set -u
if [ "$(id -u)" != 0 ]; then echo "Run it with sudo: sudo $0 $*"; exit 1; fi
CONF_DIR=/usr/local/etc/devourer-sta
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$CONF_DIR/devourer-sta.conf" 2>/dev/null || { echo "Not installed (no $CONF_DIR). Run: just install"; exit 1; }
. "$HERE/devourer-sta-lib.sh"

want="${1:-}"
case "$want" in
  auto|adapter|builtin) ;;
  *) echo "usage: $0 auto|adapter|builtin"; exit 2 ;;
esac

if ! pgrep -f devourer-sta-run.sh >/dev/null; then
  echo "The daemon is not running. Start it first: just start"
  exit 1
fi

if [ "$want" = adapter ]; then
  ip=$(ipconfig getifaddr "$IFACE" 2>/dev/null)
  gw=$(dhcp_router "$IFACE")
  if [ -z "$ip" ] || [ -z "$gw" ]; then
    echo "Refused: $IFACE has no DHCP lease yet. Check: just status"
    exit 1
  fi
  got=$(ping -q -c 3 -i 0.3 -t 4 -b "$IFACE" "$gw" 2>/dev/null |
        awk '/packets received/{print $4}')
  if [ "${got:-0}" -lt 2 ]; then
    echo "Refused: the router answered ${got:-0} of 3 pings on $IFACE."
    exit 1
  fi
  if ! ping -q -c 2 -t 4 -b "$IFACE" 1.1.1.1 >/dev/null 2>&1; then
    echo "Refused: no internet (1.1.1.1) through $IFACE."
    exit 1
  fi
  echo adapter > "$CONF_DIR/mode"
  host=$(scutil --get LocalHostName 2>/dev/null)
  cat <<EOF
Adapter mode set. Within about 10 s the built-in Wi-Fi turns off.

A Screen Sharing or SSH session over the built-in Wi-Fi will drop now.
Reconnect to the adapter's address:  $ip   (or ${host:-this-mac}.local)

Failsafe: if the adapter link is down for 30 s, or there is no internet for
30 s, the daemon turns the built-in Wi-Fi back on. To undo by hand: just wifi-on
EOF
else
  echo "$want" > "$CONF_DIR/mode"
  echo "Mode $want set. The built-in Wi-Fi is on within about 5 s."
  [ "$want" = builtin ] && echo "Internet goes over the built-in Wi-Fi; the adapter stays joined."
fi
