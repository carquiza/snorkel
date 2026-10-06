#!/bin/bash
# Install Snorkel as a launchd daemon. Run with sudo from the repo after a
# build (`just install` does both):
#
#   sudo macos/install.sh [ssid [channel]]
#
# The SSID is required on the first install; later runs keep the installed
# one unless a new one is given. The channel is where the network is (see
# snorkel-ssid.sh).
#
# Copies the binary and scripts to root-owned places (so nothing a normal
# user can edit runs as root), stores the Wi-Fi password in a root-only file
# read from the Keychain, and starts the daemon. Safe to re-run: it stops the
# old daemon first and keeps an edited config.
set -u
if [ "$(id -u)" != 0 ]; then echo "Run it with sudo: sudo $0"; exit 1; fi
cd "$(dirname "$0")/.." || exit 1
. macos/snorkel-lib.sh
NEW_SSID="${1:-}"
NEW_CHANNEL="${2:-}"
if [ -n "$NEW_CHANNEL" ] && ! valid_channel "$NEW_CHANNEL"; then
  echo "Not a Wi-Fi channel: $NEW_CHANNEL"; exit 2
fi

HOME_DIR=/usr/local/libexec/snorkel
CONF_DIR=/usr/local/etc/snorkel
PLIST=/Library/LaunchDaemons/local.snorkel.plist
LABEL=local.snorkel

[ -x build/sta_client ] || { echo "build/sta_client is missing - build first"; exit 1; }

launchctl bootout system/$LABEL >/dev/null 2>&1
# Any other daemon that runs this same script (an install under an earlier
# label) would fight this one for the adapter.
for p in /Library/LaunchDaemons/*.plist; do
  [ "$p" = "$PLIST" ] && continue
  grep -q "$HOME_DIR/snorkel-run.sh" "$p" 2>/dev/null || continue
  echo "Removing $p (an earlier install under another label)"
  launchctl bootout system "$p" >/dev/null 2>&1
  rm -f "$p"
done
install -d -o root -g wheel -m 755 "$HOME_DIR" "$CONF_DIR"

# An install from before the rename (devourer-sta): stop it, keep its config,
# password and mode, and remove the rest.
OLD_LABEL=com.openipc.devourer-sta
OLD_CONF=/usr/local/etc/devourer-sta
if [ -f /Library/LaunchDaemons/$OLD_LABEL.plist ] || [ -d "$OLD_CONF" ]; then
  echo "Moving the old devourer-sta install to $CONF_DIR"
  launchctl bootout system/$OLD_LABEL >/dev/null 2>&1
  [ -f "$CONF_DIR/snorkel.conf" ] || cp -p "$OLD_CONF/devourer-sta.conf" "$CONF_DIR/snorkel.conf" 2>/dev/null
  for f in psk mode; do
    [ -f "$CONF_DIR/$f" ] || cp -p "$OLD_CONF/$f" "$CONF_DIR/$f" 2>/dev/null
  done
  rm -f /Library/LaunchDaemons/$OLD_LABEL.plist
  rm -rf /usr/local/libexec/devourer-sta "$OLD_CONF"
fi

install -o root -g wheel -m 755 build/sta_client "$HOME_DIR/sta_client"
install -o root -g wheel -m 755 macos/snorkel-run.sh "$HOME_DIR/snorkel-run.sh"
install -o root -g wheel -m 644 macos/snorkel-lib.sh "$HOME_DIR/snorkel-lib.sh"
# An installed config without an SSID is replaced by the default.
if [ -f "$CONF_DIR/snorkel.conf" ] &&
   ! cmp -s macos/snorkel.conf "$CONF_DIR/snorkel.conf" &&
   ( . "$CONF_DIR/snorkel.conf"; [ -n "$SSID" ] ); then
  echo "Keeping your edited $CONF_DIR/snorkel.conf (new default saved as .new)"
  install -o root -g wheel -m 644 macos/snorkel.conf "$CONF_DIR/snorkel.conf.new"
else
  install -o root -g wheel -m 644 macos/snorkel.conf "$CONF_DIR/snorkel.conf"
fi

if [ -n "$NEW_SSID" ]; then
  # A different network needs its own password.
  [ "$( . "$CONF_DIR/snorkel.conf"; echo "$SSID")" = "$NEW_SSID" ] || rm -f "$CONF_DIR/psk"
  set_conf "$CONF_DIR/snorkel.conf" SSID "$NEW_SSID"
fi
if [ -n "$NEW_CHANNEL" ]; then
  set_conf "$CONF_DIR/snorkel.conf" CHANNEL "$NEW_CHANNEL"
  set_conf "$CONF_DIR/snorkel.conf" SCAN_CHANNELS "$NEW_CHANNEL"
fi

. "$CONF_DIR/snorkel.conf"
if [ -z "$SSID" ]; then
  echo "No network set. Install with your network's name: just install \"<ssid>\""
  exit 1
fi
if [ ! -s "$CONF_DIR/psk" ]; then
  store_psk "$SSID" "$CONF_DIR/psk" || { echo "Stopped."; exit 1; }
fi

[ -f "$CONF_DIR/mode" ] || echo auto > "$CONF_DIR/mode"
chmod 644 "$CONF_DIR/mode"
install -o root -g wheel -m 644 macos/local.snorkel.plist "$PLIST"
touch /var/log/snorkel.log /var/log/snorkel-daemon.log
chmod 644 /var/log/snorkel.log /var/log/snorkel-daemon.log
launchctl bootstrap system "$PLIST" && launchctl enable system/$LABEL
echo "Installed and started. Logs: /var/log/snorkel.log and /var/log/snorkel-daemon.log"
echo "Network: $SSID (channels $SCAN_CHANNELS). Mode: $(cat "$CONF_DIR/mode")."
echo "Check it in about 20 s with: just status"
