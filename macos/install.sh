#!/bin/bash
# Install Snorkel as a launchd daemon. Run with sudo from the
# repo after a build: sudo macos/install.sh
#
# Copies the binary and scripts to root-owned places (so nothing a normal
# user can edit runs as root), stores the Wi-Fi password in a root-only file
# read from the Keychain, and starts the daemon. Safe to re-run: it stops the
# old daemon first and keeps an edited config.
set -u
if [ "$(id -u)" != 0 ]; then echo "Run it with sudo: sudo $0"; exit 1; fi
cd "$(dirname "$0")/.." || exit 1

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
# An installed config without an SSID is replaced, so editing the repo copy
# and re-running works on a first install.
if [ -f "$CONF_DIR/snorkel.conf" ] &&
   ! cmp -s macos/snorkel.conf "$CONF_DIR/snorkel.conf" &&
   ( . "$CONF_DIR/snorkel.conf"; [ -n "$SSID" ] ); then
  echo "Keeping your edited $CONF_DIR/snorkel.conf (new default saved as .new)"
  install -o root -g wheel -m 644 macos/snorkel.conf "$CONF_DIR/snorkel.conf.new"
else
  install -o root -g wheel -m 644 macos/snorkel.conf "$CONF_DIR/snorkel.conf"
fi

. "$CONF_DIR/snorkel.conf"
if [ -z "$SSID" ]; then
  echo "No SSID set. Put your network's name in macos/snorkel.conf and run this again."
  exit 1
fi
if [ ! -s "$CONF_DIR/psk" ]; then
  echo "Reading the $SSID password from the Keychain (approve the dialog if one shows)."
  PSK="$(security find-generic-password -D 'AirPort network password' \
    -a "$SSID" -w /Library/Keychains/System.keychain 2>/dev/null)"
  if [ -z "$PSK" ]; then echo "No password read for $SSID. Stopped."; exit 1; fi
  ( umask 077; printf '%s' "$PSK" > "$CONF_DIR/psk" )
  unset PSK
  chown root:wheel "$CONF_DIR/psk"
  chmod 600 "$CONF_DIR/psk"
fi

[ -f "$CONF_DIR/mode" ] || echo auto > "$CONF_DIR/mode"
chmod 644 "$CONF_DIR/mode"
install -o root -g wheel -m 644 macos/local.snorkel.plist "$PLIST"
touch /var/log/snorkel.log /var/log/snorkel-daemon.log
chmod 644 /var/log/snorkel.log /var/log/snorkel-daemon.log
launchctl bootstrap system "$PLIST" && launchctl enable system/$LABEL
echo "Installed and started. Logs: /var/log/snorkel.log and /var/log/snorkel-daemon.log"
echo "Mode: $(cat "$CONF_DIR/mode"). Check it with: just status"
