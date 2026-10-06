# Snorkel on macOS: an Archer T3U Plus (RTL8822BU) as this Mac's
# Wi-Fi, with no kext and SIP on. Full guide: macos/README.md.
#
# Recipes that change the system ask for your password (sudo).

set shell := ["bash", "-cu"]

station_tests := "sta_client_headless|station_sm|supplicant|ccmp_framing|dot11_frames|bss_table|sta_reorder|station_arm"

# List the recipes.
default:
    @just --list --unsorted

# Build sta_client (Jaguar1 and RTL8733B off: AppleClang 14 has no std::jthread).
build:
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DDEVOURER_JAGUAR1=OFF -DDEVOURER_8814=OFF -DDEVOURER_8733B=OFF \
      -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" > /dev/null
    ninja -C build StaClientSelftest

# Build and run the headless station tests (no adapter, no root).
test: build
    ninja -C build StationSmSelftest SupplicantSelftest CcmpSelftest \
      Dot11Selftest BssTableSelftest ReorderSelftest StationArmSelftest
    cd build && ctest --output-on-failure -R "{{station_tests}}"

# One-shot on-air test: join, DHCP, ping, speed, default-route switch (~3 min). Stop the daemon first.
datapath-test: build
    sudo macos/sta-datapath-test.sh

# Build, install and start the daemon. First time: just install "<ssid>" [channel]. Re-run after any change.
install ssid="" channel="": build
    sudo macos/install.sh {{quote(ssid)}} {{quote(channel)}}

# Show the network, or join another: just ssid "<ssid>" [channel] (reads its password, restarts).
ssid name="" channel="":
    @if [ -z {{quote(name)}} ]; then macos/snorkel-ssid.sh; else sudo macos/snorkel-ssid.sh {{quote(name)}} {{quote(channel)}}; fi

# Stop the daemon and remove everything it installed; the built-in Wi-Fi is turned on.
uninstall:
    sudo macos/uninstall.sh

# Start the installed daemon.
start:
    sudo launchctl bootstrap system /Library/LaunchDaemons/local.snorkel.plist

# Stop the daemon (the built-in Wi-Fi is turned on as it stops).
stop:
    sudo launchctl bootout system/local.snorkel

# Restart the daemon (re-reads the config).
restart:
    sudo launchctl kickstart -k system/local.snorkel

# Show the daemon, the mode, both Wi-Fi interfaces, routes, DNS and the last link line.
status:
    @macos/snorkel-status.sh

# Follow the station and daemon logs.
logs:
    tail -F /var/log/snorkel.log /var/log/snorkel-daemon.log

# Follow only the state changes and the 2 s link lines.
link:
    tail -F /var/log/snorkel.log | grep --line-buffered -E "station state|link:|block ack: TID"

# Switch to the adapter and turn the built-in Wi-Fi off (checked first; failsafe back on).
wifi-off:
    sudo macos/snorkel-mode.sh adapter

# Turn the built-in Wi-Fi back on; internet stays on the adapter while it is healthy.
wifi-on:
    sudo macos/snorkel-mode.sh auto

# Built-in Wi-Fi on and carrying all traffic; the adapter stays joined but idle.
use-builtin:
    sudo macos/snorkel-mode.sh builtin

# Open the installed config in an editor, then restart the daemon.
config:
    sudo "${EDITOR:-nano}" /usr/local/etc/snorkel/snorkel.conf
    sudo launchctl kickstart -k system/local.snorkel
