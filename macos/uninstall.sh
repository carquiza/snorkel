#!/bin/bash
# Remove the devourer station daemon and everything install.sh put in place,
# including the stored Wi-Fi password. The built-in Wi-Fi is untouched.
set -u
if [ "$(id -u)" != 0 ]; then echo "Run it with sudo: sudo $0"; exit 1; fi
LABEL=com.openipc.devourer-sta
launchctl bootout system/$LABEL >/dev/null 2>&1
route -n delete -net 0.0.0.0/1 >/dev/null 2>&1
route -n delete -net 128.0.0.0/1 >/dev/null 2>&1
ipconfig set feth0 NONE >/dev/null 2>&1
ifconfig feth0 destroy >/dev/null 2>&1
ifconfig feth5000 destroy >/dev/null 2>&1
rm -f /Library/LaunchDaemons/$LABEL.plist
rm -rf /usr/local/libexec/devourer-sta /usr/local/etc/devourer-sta
echo "Removed. Logs are left in /var/log/devourer-sta*.log"
