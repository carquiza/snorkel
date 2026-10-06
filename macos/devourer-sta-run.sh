#!/bin/bash
# The devourer station daemon body, run by launchd as root.
#
# Loops sta_client (it creates feth0 and joins), keeps DHCP on feth0, routes
# internet traffic through feth0 while the router answers there, and - in
# adapter mode - turns the built-in Wi-Fi off, with a failsafe that turns it
# back on when the adapter stops working. Full description: macos/README.md.
#
# Modes ($CONF_DIR/mode, written by macos/devourer-sta-mode.sh):
#   auto     built-in Wi-Fi on; internet via the adapter while it is healthy
#   adapter  as auto, and the built-in Wi-Fi off while the adapter is healthy
#   builtin  built-in Wi-Fi on; the adapter stays joined but carries nothing
#
# Routing uses two half-default routes (0/1 and 128/1) via -ifp feth0. They
# win over the default route without touching it: macOS ignored PrimaryRank
# for the ipconfig-only feth0 service. LAN traffic stays on the built-in Wi-Fi
# while it is on.
set -u
HOME_DIR=/usr/local/libexec/devourer-sta
CONF_DIR=/usr/local/etc/devourer-sta
LOG=/var/log/devourer-sta.log
MODE_FILE="$CONF_DIR/mode"
. "$CONF_DIR/devourer-sta.conf"
. "$HOME_DIR/devourer-sta-lib.sh"

PSK="$(cat "$CONF_DIR/psk" 2>/dev/null)"
if [ -z "$PSK" ]; then echo "no PSK in $CONF_DIR/psk"; sleep 60; exit 1; fi

WIFI_DEV=$(builtin_wifi_dev)
# A fixed service ID for the DNS/IPv4 state this daemon publishes for feth0
# when the built-in Wi-Fi is off and macOS has no DNS left (see ensure_dns).
DNS_SVC=7F3C1E52-6B0D-4D3A-9E41-DE0A5A7A0001

CPID=""
ROUTED=""
DNS_PUBLISHED=0

note() { echo "$(date '+%F %T') $*"; }

mode() {
  case "$(cat "$MODE_FILE" 2>/dev/null)" in
    adapter) echo adapter ;;
    builtin) echo builtin ;;
    *) echo auto ;;
  esac
}

unroute() {
  if [ -n "$ROUTED" ]; then
    route -n delete -net 0.0.0.0/1 >/dev/null 2>&1
    route -n delete -net 128.0.0.0/1 >/dev/null 2>&1
    note "routes: internet off the adapter"
    ROUTED=""
  fi
}

route_via() {
  route -n add -net 0.0.0.0/1 "$1" -ifp "$IFACE" >/dev/null 2>&1 &&
  route -n add -net 128.0.0.0/1 "$1" -ifp "$IFACE" >/dev/null 2>&1 &&
  ROUTED="$1" && note "routes: internet via $IFACE (router $1)"
}

# macOS takes DNS from its primary service. With the built-in Wi-Fi off and
# feth0 configured only through ipconfig, there may be none: then publish
# feth0's DHCP answers as a service of our own, the way VPN up-scripts do.
ensure_dns() {
  [ "$DNS_PUBLISHED" = 1 ] && return
  scutil --dns 2>/dev/null | grep -q "nameserver\[0\]" && return
  local ip mask gw dns
  ip=$(ipconfig getifaddr "$IFACE")
  mask=$(ipconfig getoption "$IFACE" subnet_mask)
  gw=$(dhcp_router "$IFACE")
  dns=$(ipconfig getoption "$IFACE" domain_name_server)
  [ -n "$ip" ] && [ -n "$dns" ] || return
  scutil <<EOF
d.init
d.add Addresses * $ip
d.add SubnetMasks * ${mask:-255.255.255.0}
d.add Router $gw
d.add InterfaceName $IFACE
set State:/Network/Service/$DNS_SVC/IPv4
d.init
d.add ServerAddresses * $dns
set State:/Network/Service/$DNS_SVC/DNS
EOF
  DNS_PUBLISHED=1
  note "dns: none left with the built-in Wi-Fi off; published $dns for $IFACE"
}

drop_dns() {
  if [ "$DNS_PUBLISHED" = 1 ]; then
    printf 'remove State:/Network/Service/%s/IPv4\nremove State:/Network/Service/%s/DNS\n' \
      "$DNS_SVC" "$DNS_SVC" | scutil
    DNS_PUBLISHED=0
    note "dns: published service removed"
  fi
}

builtin_on() {
  drop_dns
  if [ "$(wifi_power "$WIFI_DEV")" != On ]; then
    networksetup -setairportpower "$WIFI_DEV" on
    note "built-in Wi-Fi ($WIFI_DEV) on: $1"
  fi
}

builtin_off() {
  if [ "$(wifi_power "$WIFI_DEV")" = On ]; then
    networksetup -setairportpower "$WIFI_DEV" off
    note "built-in Wi-Fi ($WIFI_DEV) off: $1"
  fi
}

# Internet through whatever the routing table says: an address and a name.
internet_ok() {
  ping -q -c 1 -t 3 1.1.1.1 >/dev/null 2>&1 &&
  [ -n "$(dig +short +time=2 +tries=1 www.apple.com 2>/dev/null | head -1)" ]
}

stop_client() {
  unroute
  ipconfig set "$IFACE" NONE >/dev/null 2>&1
  if [ -n "$CPID" ] && kill -0 "$CPID" 2>/dev/null; then
    kill -INT "$CPID"
    for _ in $(seq 20); do kill -0 "$CPID" 2>/dev/null || break; sleep 0.5; done
    kill -9 "$CPID" 2>/dev/null
  fi
  CPID=""
}

# Leaving for any reason: the Mac must keep a way onto the network.
trap 'stop_client; builtin_on "daemon stopping"; exit 0' TERM INT

note "daemon up (mode $(mode))"
while :; do
  # Keep the client log bounded: start fresh when it passes 20 MB.
  if [ -f "$LOG" ] && [ "$(stat -f %z "$LOG")" -gt 20000000 ]; then
    mv -f "$LOG" "$LOG.1"
  fi
  note "starting sta_client ($SSID ch$CHANNEL, data $TX_RATE, base $BASE_RATE)"
  DEVOURER_STA_PSK="$PSK" DEVOURER_VID="$VID" DEVOURER_PID="$PID" \
  DEVOURER_CHANNEL="$CHANNEL" DEVOURER_STA_SSID="$SSID" \
  DEVOURER_STA_SCAN_CHANNELS="$SCAN_CHANNELS" DEVOURER_TX_RATE="$TX_RATE" \
  DEVOURER_STA_BASE_RATE="$BASE_RATE" DEVOURER_STA_TAP="$IFACE" \
  DEVOURER_STA_HT="${HT:-0}" DEVOURER_STA_BA="${BA:-0}" DEVOURER_STA_ACK_RATES="$ACK_RATES" DEVOURER_IGI_MAX="$IGI_MAX" \
  DEVOURER_LOG_LEVEL=warn DEVOURER_STA_LINK_LOG=1 \
    "$HOME_DIR/sta_client" 86400 >> "$LOG" 2>&1 &
  CPID=$!
  chmod 644 "$LOG" 2>/dev/null

  DHCP_SET=0
  OK=0          # consecutive 5 s ticks the router answered on feth0
  BAD=0         # consecutive ticks it did not
  NET_BAD=0     # consecutive ticks with no internet while the built-in is off
  while kill -0 "$CPID" 2>/dev/null; do
    sleep 5
    MODE=$(mode)
    if ! ifconfig "$IFACE" >/dev/null 2>&1; then
      BAD=$((BAD + 1)); OK=0
    else
      if [ "$DHCP_SET" = 0 ]; then
        ipconfig set "$IFACE" DHCP && DHCP_SET=1
      fi
      GW=$(dhcp_router "$IFACE")
      if [ -n "$GW" ] && ping -q -c 1 -t 2 -b "$IFACE" "$GW" >/dev/null 2>&1; then
        OK=$((OK + 1)); BAD=0
      else
        BAD=$((BAD + 1)); OK=0
      fi
    fi

    # Routing: through the adapter while it answers, unless told not to.
    if [ "$MODE" = builtin ] || [ "$BAD" -ge 2 ]; then
      unroute
    elif [ -z "$ROUTED" ] && [ "$OK" -ge 2 ]; then
      route_via "$GW"
    fi

    # The built-in Wi-Fi.
    if [ "$MODE" != adapter ]; then
      builtin_on "mode $MODE"
      NET_BAD=0
    elif [ "$(wifi_power "$WIFI_DEV")" = On ]; then
      [ "$OK" -ge 2 ] && [ -n "$ROUTED" ] && builtin_off "adapter mode, adapter healthy"
    else
      ensure_dns
      if [ "$BAD" -ge 6 ]; then
        builtin_on "failsafe: adapter link down for 30 s"
      elif internet_ok; then
        NET_BAD=0
      else
        NET_BAD=$((NET_BAD + 1))
        if [ "$NET_BAD" -ge 6 ]; then
          # The link is up but the internet is not: switching off again would
          # only repeat this, so adapter mode is given up until asked again.
          echo auto > "$MODE_FILE"
          builtin_on "failsafe: no internet for 30 s with the adapter alone; mode set to auto"
          NET_BAD=0
        fi
      fi
    fi
  done
  wait "$CPID" 2>/dev/null
  note "sta_client exited (status $?); restarting in 5 s"
  stop_client
  [ "$(mode)" = adapter ] && builtin_on "failsafe: adapter restarting"
  sleep 5
done
