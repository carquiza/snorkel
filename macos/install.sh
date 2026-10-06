#!/bin/bash
# Install the devourer station as a launchd daemon. Run with sudo from the
# repo after a build: sudo macos/install.sh
#
# Copies the binary and scripts to root-owned places (so nothing a normal
# user can edit runs as root), stores the Wi-Fi password in a root-only file
# read from the Keychain, and starts the daemon. Safe to re-run: it stops the
# old daemon first and keeps an edited config.
set -u
if [ "$(id -u)" != 0 ]; then echo "Run it with sudo: sudo $0"; exit 1; fi
cd "$(dirname "$0")/.." || exit 1

HOME_DIR=/usr/local/libexec/devourer-sta
CONF_DIR=/usr/local/etc/devourer-sta
PLIST=/Library/LaunchDaemons/com.openipc.devourer-sta.plist
LABEL=com.openipc.devourer-sta

[ -x build/sta_client ] || { echo "build/sta_client is missing - build first"; exit 1; }

launchctl bootout system/$LABEL >/dev/null 2>&1

install -d -o root -g wheel -m 755 "$HOME_DIR" "$CONF_DIR"
install -o root -g wheel -m 755 build/sta_client "$HOME_DIR/sta_client"
install -o root -g wheel -m 755 macos/devourer-sta-run.sh "$HOME_DIR/devourer-sta-run.sh"
install -o root -g wheel -m 644 macos/devourer-sta-lib.sh "$HOME_DIR/devourer-sta-lib.sh"
if [ -f "$CONF_DIR/devourer-sta.conf" ] &&
   ! cmp -s macos/devourer-sta.conf "$CONF_DIR/devourer-sta.conf"; then
  echo "Keeping your edited $CONF_DIR/devourer-sta.conf (new default saved as .new)"
  install -o root -g wheel -m 644 macos/devourer-sta.conf "$CONF_DIR/devourer-sta.conf.new"
else
  install -o root -g wheel -m 644 macos/devourer-sta.conf "$CONF_DIR/devourer-sta.conf"
fi

. "$CONF_DIR/devourer-sta.conf"
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

install -o root -g wheel -m 644 macos/com.openipc.devourer-sta.plist "$PLIST"
touch /var/log/devourer-sta.log /var/log/devourer-sta-daemon.log
chmod 644 /var/log/devourer-sta.log /var/log/devourer-sta-daemon.log
launchctl bootstrap system "$PLIST" && launchctl enable system/$LABEL
echo "Installed and started. Logs: /var/log/devourer-sta.log and /var/log/devourer-sta-daemon.log"
echo "Stop it with: sudo macos/uninstall.sh"
