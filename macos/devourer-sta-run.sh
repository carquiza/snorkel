#!/bin/bash
# The devourer station daemon body, run by launchd as root.
#
# Loops sta_client (it creates feth0 and joins), keeps DHCP on feth0, and
# routes internet traffic through feth0 while the router answers pings there.
# Routing uses two half-default routes (0/1 and 128/1) via -ifp feth0, which
# win over the default route without touching it: macOS ignored PrimaryRank
# for the ipconfig-only feth0 service. LAN traffic stays on the built-in
# Wi-Fi, which also remains the fallback - the half routes are removed as soon
# as the adapter link fails.
set -u
HOME_DIR=/usr/local/libexec/devourer-sta
CONF_DIR=/usr/local/etc/devourer-sta
LOG=/var/log/devourer-sta.log
. "$CONF_DIR/devourer-sta.conf"
. "$HOME_DIR/devourer-sta-lib.sh"

PSK="$(cat "$CONF_DIR/psk" 2>/dev/null)"
if [ -z "$PSK" ]; then echo "no PSK in $CONF_DIR/psk"; sleep 60; exit 1; fi

CPID=""
ROUTED=""

note() { echo "$(date '+%F %T') $*"; }

unroute() {
  if [ -n "$ROUTED" ]; then
    route -n delete -net 0.0.0.0/1 >/dev/null 2>&1
    route -n delete -net 128.0.0.0/1 >/dev/null 2>&1
    note "routes: internet back on the built-in Wi-Fi"
    ROUTED=""
  fi
}

route_via() {
  route -n add -net 0.0.0.0/1 "$1" -ifp "$IFACE" >/dev/null 2>&1 &&
  route -n add -net 128.0.0.0/1 "$1" -ifp "$IFACE" >/dev/null 2>&1 &&
  ROUTED="$1" && note "routes: internet via $IFACE (router $1)"
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
trap 'stop_client; exit 0' TERM INT

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
  OK=0
  BAD=0
  while kill -0 "$CPID" 2>/dev/null; do
    sleep 5
    if ! ifconfig "$IFACE" >/dev/null 2>&1; then continue; fi
    if [ "$DHCP_SET" = 0 ]; then
      ipconfig set "$IFACE" DHCP && DHCP_SET=1
      continue
    fi
    GW=$(dhcp_router "$IFACE")
    if [ -n "$GW" ] && ping -q -c 1 -t 2 -b "$IFACE" "$GW" >/dev/null 2>&1; then
      OK=$((OK + 1)); BAD=0
      [ -z "$ROUTED" ] && [ "$OK" -ge 2 ] && route_via "$GW"
    else
      BAD=$((BAD + 1)); OK=0
      [ "$BAD" -ge 2 ] && unroute
    fi
  done
  wait "$CPID" 2>/dev/null
  note "sta_client exited (status $?); restarting in 5 s"
  stop_client
  sleep 5
done
