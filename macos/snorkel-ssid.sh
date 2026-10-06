#!/bin/bash
# Show or change the network Snorkel joins. Changing needs sudo.
#
#   snorkel-ssid.sh                    show the network and its channels
#   snorkel-ssid.sh <ssid> [channel]   join <ssid>; restarts the daemon
#
# Sets SSID in the installed config, stores that network's password
# (from the System keychain, or typed in), and restarts the daemon. The
# station only looks on CHANNEL and SCAN_CHANNELS, so give the channel when
# the network is not on the ones shown; it then looks there alone (edit
# SCAN_CHANNELS with `just config` for a list). Running it again with the
# same SSID re-reads the password, e.g. after it changed.
set -u
CONF_DIR=/usr/local/etc/snorkel
LABEL=local.snorkel
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/snorkel-lib.sh"

if [ ! -f "$CONF_DIR/snorkel.conf" ]; then
  echo "Not installed. Run: just install \"<ssid>\""
  exit 1
fi
. "$CONF_DIR/snorkel.conf"

if [ $# -eq 0 ]; then
  echo "network:  ${SSID:-(none)}"
  echo "channel:  $CHANNEL (looks on $SCAN_CHANNELS)"
  exit 0
fi

ssid="$1"
channel="${2:-}"
if [ "$(id -u)" != 0 ]; then echo "Run it with sudo: sudo $0 $*"; exit 1; fi
if [ -n "$channel" ] && ! valid_channel "$channel"; then
  echo "Not a Wi-Fi channel: $channel"; exit 2
fi

store_psk "$ssid" "$CONF_DIR/psk.new" || { rm -f "$CONF_DIR/psk.new"; exit 1; }
mv -f "$CONF_DIR/psk.new" "$CONF_DIR/psk"
set_conf "$CONF_DIR/snorkel.conf" SSID "$ssid"
if [ -n "$channel" ]; then
  set_conf "$CONF_DIR/snorkel.conf" CHANNEL "$channel"
  set_conf "$CONF_DIR/snorkel.conf" SCAN_CHANNELS "$channel"
  SCAN_CHANNELS="$channel"
fi
echo "Network set to $ssid (looks on channels $SCAN_CHANNELS)."

if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "system/$LABEL"
  echo "Daemon restarted. Check in about 20 s with: just status"
  echo "If it does not join, the network may be on another channel: just ssid \"$ssid\" <channel>"
else
  echo "The daemon is not running. Start it with: just start"
fi
