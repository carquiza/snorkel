#!/bin/bash
# Remove the devourer station daemon and everything install.sh put in place,
# including the stored Wi-Fi password, and turn the built-in Wi-Fi back on.
set -u
if [ "$(id -u)" != 0 ]; then echo "Run it with sudo: sudo $0"; exit 1; fi
LABEL=com.openipc.devourer-sta
launchctl bootout system/$LABEL >/dev/null 2>&1
route -n delete -net 0.0.0.0/1 >/dev/null 2>&1
route -n delete -net 128.0.0.0/1 >/dev/null 2>&1
ipconfig set feth0 NONE >/dev/null 2>&1
ifconfig feth0 destroy >/dev/null 2>&1
ifconfig feth5000 destroy >/dev/null 2>&1
printf 'remove State:/Network/Service/7F3C1E52-6B0D-4D3A-9E41-DE0A5A7A0001/IPv4\nremove State:/Network/Service/7F3C1E52-6B0D-4D3A-9E41-DE0A5A7A0001/DNS\n' | scutil
WIFI_DEV=$(networksetup -listallhardwareports | awk '/^Hardware Port: Wi-Fi/{getline; print $2; exit}')
[ -n "$WIFI_DEV" ] && networksetup -setairportpower "$WIFI_DEV" on
rm -f /Library/LaunchDaemons/$LABEL.plist
rm -rf /usr/local/libexec/devourer-sta /usr/local/etc/devourer-sta
echo "Removed. Logs are left in /var/log/devourer-sta*.log"
