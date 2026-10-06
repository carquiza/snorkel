#!/bin/bash
# One-shot test of the macOS data path. Run with sudo; takes about 3 minutes.
#
#  1. Joins $SSID with the Archer T3U Plus through sta_client, with feth0 as
#     the host interface, and gets a DHCP lease on it.
#  2. Pings the router and measures download/upload, through feth0 and
#     through the built-in Wi-Fi, for comparison.
#  3. For about 30 seconds makes feth0 the default route, tests it, and puts
#     the built-in Wi-Fi back. Screen Sharing can pause during this step.
#
# Everything is undone on exit, also on Ctrl-C. The password is never printed,
# and any copy of it in the logs is replaced with <redacted>.
# Results: logs/datapath-summary.txt (short) and logs/datapath-client.log.
set -u
if [ "$(id -u)" != 0 ]; then echo "Run it with sudo: sudo $0"; exit 1; fi
cd "$(dirname "$0")/.." || exit 1
. macos/devourer-sta.conf
. macos/devourer-sta-lib.sh
mkdir -p logs
CLOG=logs/datapath-client.log
SUM=logs/datapath-summary.txt
: > "$SUM"
say() { echo "$*" | tee -a "$SUM"; }

PEER="feth$(( ${IFACE#feth} + 5000 ))"
WIFI_DEV=$(builtin_wifi_dev)
WIFI_ID=""
ROUTES_ADDED=0
CPID=""
PSK=""
DL_URL='https://speed.cloudflare.com/__down?bytes=25000000'
UL_URL='https://speed.cloudflare.com/__up'

cleanup() {
  [ -n "$WIFI_ID" ] && clear_rank "$WIFI_ID" >/dev/null 2>&1
  if [ "$ROUTES_ADDED" = 1 ]; then
    route -n delete -net 0.0.0.0/1 >/dev/null 2>&1
    route -n delete -net 128.0.0.0/1 >/dev/null 2>&1
  fi
  ipconfig set "$IFACE" NONE >/dev/null 2>&1
  if [ -n "$CPID" ] && kill -0 "$CPID" 2>/dev/null; then
    kill -INT "$CPID"
    for _ in $(seq 20); do kill -0 "$CPID" 2>/dev/null || break; sleep 0.5; done
    kill -9 "$CPID" 2>/dev/null
  fi
  ifconfig "$IFACE" destroy >/dev/null 2>&1
  ifconfig "$PEER" destroy >/dev/null 2>&1
  if [ -n "$PSK" ]; then
    PSK="$PSK" perl -pi -e 's/\Q$ENV{PSK}\E/<redacted>/g' "$CLOG" "$SUM"
  fi
  unset PSK
  rm -f logs/upload.bin
  [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$CLOG" "$SUM" 2>/dev/null
  say "default route now: $(default_route_if)"
  grep -E "station state|link:" "$CLOG" > logs/datapath-link.txt
  [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" logs/datapath-link.txt 2>/dev/null
  say "drops: $(grep -c 'station state: Failed' "$CLOG") ($(grep 'station state: Failed' "$CLOG" | sed 's/.*reason=\([a-z-]*\).*/\1/' | sort | uniq -c | tr '\n' ' '))"
  say "rx rates (data to us): $(awk '/link:/{for(i=1;i<=NF;i++){split($i,kv,"=");if(kv[1]=="ht")h+=kv[2];if(kv[1]=="legacy")l+=kv[2];if(kv[1]=="mcs_max"&&kv[2]>m)m=kv[2]}}END{printf "ht %d, legacy %d, highest MCS %d", h, l, m}' logs/datapath-link.txt)"
  say "== ledger =="
  sed -n '/^fault=/,$p' "$CLOG" | tee -a "$SUM"
  echo
  echo "Done. Tell Claude the test finished."
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mbps() { awk -v b="$1" 'BEGIN{printf "%.1f", b*8/1e6}'; }

# download <curl --interface args...>: prints Mbps
download() {
  curl "$@" -s -o /dev/null --max-time 30 -w '%{speed_download}' "$DL_URL"
}
upload() {
  curl "$@" -s -o /dev/null --max-time 30 -w '%{speed_upload}' \
    --data-binary @logs/upload.bin "$UL_URL"
}

say "== devourer data path test $(date '+%F %T') =="
say "built-in $WIFI_DEV: $(/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I | awk '/agrCtlRSSI/{r=$2}/lastTxRate/{t=$2}END{print "rssi " r " dBm, tx " t " Mbps"}')"
say "default route before: $(default_route_if)"

echo "Reading the $SSID password from the Keychain (approve the dialog if one shows)."
PSK="$(security find-generic-password -D 'AirPort network password' \
  -a "$SSID" -w /Library/Keychains/System.keychain 2>/dev/null)"
if [ -z "$PSK" ]; then say "FAIL: no password read for $SSID"; exit 1; fi

say "-- 1. join $SSID (HT ${HT:-0}, data $TX_RATE, base $BASE_RATE)"
DEVOURER_STA_PSK="$PSK" DEVOURER_VID="$VID" DEVOURER_PID="$PID" \
DEVOURER_CHANNEL="$CHANNEL" DEVOURER_STA_SSID="$SSID" \
DEVOURER_STA_SCAN_CHANNELS="$SCAN_CHANNELS" DEVOURER_TX_RATE="$TX_RATE" \
DEVOURER_STA_BASE_RATE="$BASE_RATE" DEVOURER_STA_TAP="$IFACE" \
DEVOURER_STA_HT="${HT:-0}" DEVOURER_STA_ACK_RATES="$ACK_RATES" DEVOURER_IGI_MAX="$IGI_MAX" DEVOURER_LOG_LEVEL=warn DEVOURER_STA_LINK_LOG=1 \
  ./build/sta_client 600 > "$CLOG" 2>&1 &
CPID=$!
T0=$SECONDS
until grep -q "station state: Connected" "$CLOG"; do
  if ! kill -0 "$CPID" 2>/dev/null; then
    say "FAIL: sta_client exited before connecting"
    grep -E "TAP|refus|fail" "$CLOG" | head -5 | tee -a "$SUM"
    exit 1
  fi
  if (( SECONDS - T0 > 45 )); then say "FAIL: not connected after 45 s"; exit 1; fi
  sleep 1
done
say "connected after $((SECONDS - T0)) s; $(grep -m1 'TAP:' "$CLOG" | sed 's/^ *//')"
say "$(grep -m1 'response rates' "$CLOG" | sed 's/^ *//')"

say "-- 2. DHCP on $IFACE"
ipconfig set "$IFACE" DHCP
T0=$SECONDS
IP=""
until [ -n "$IP" ]; do
  IP=$(ipconfig getifaddr "$IFACE" 2>/dev/null)
  if (( SECONDS - T0 > 45 )); then say "FAIL: no DHCP lease after 45 s"; exit 1; fi
  [ -z "$IP" ] && sleep 1
done
GW=$(dhcp_router "$IFACE")
say "lease after $((SECONDS - T0)) s: $IP, router $GW"

say "-- 3. ping the router (20 pings each)"
for dev in "$IFACE" "$WIFI_DEV"; do
  say "$dev: $(ping -q -c 20 -i 0.2 -b "$dev" "$GW" 2>&1 | grep -E 'packet loss|round-trip' | tr '\n' ' ')"
done

say "-- 4. download 25 MB / upload 5 MB (30 s cap each)"
dd if=/dev/urandom of=logs/upload.bin bs=1m count=5 2>/dev/null
for dev in "$IFACE" "$WIFI_DEV"; do
  d=$(download --interface "$dev"); u=$(upload --interface "$dev")
  say "$dev: down $(mbps "${d:-0}") Mbps, up $(mbps "${u:-0}") Mbps"
done

say "-- 5. make $IFACE the default route for about 30 s"
WIFI_ID=$(service_id_for "$WIFI_DEV")
METHOD=""
if [ -n "$WIFI_ID" ]; then
  set_rank_last "$WIFI_ID" >/dev/null
  sleep 5
  [ "$(default_route_if)" = "$IFACE" ] && METHOD="PrimaryRank Last on $WIFI_DEV"
fi
if [ -z "$METHOD" ]; then
  [ -n "$WIFI_ID" ] && clear_rank "$WIFI_ID" >/dev/null 2>&1
  WIFI_ID=""
  say "PrimaryRank did not move the default route (got $(default_route_if)); trying 0/1 + 128/1 via -ifp"
  route -n add -net 0.0.0.0/1 "$GW" -ifp "$IFACE" >/dev/null 2>&1 &&
  route -n add -net 128.0.0.0/1 "$GW" -ifp "$IFACE" >/dev/null 2>&1 && ROUTES_ADDED=1
  sleep 2
  [ "$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')" = "$IFACE" ] &&
    METHOD="0/1 + 128/1 routes via -ifp $IFACE"
fi
if [ -n "$METHOD" ]; then
  say "switched by: $METHOD"
  say "ping 1.1.1.1: $(ping -q -c 10 -i 0.5 1.1.1.1 2>&1 | grep -E 'packet loss|round-trip' | tr '\n' ' ')"
  d=$(download)
  say "default-route download: $(mbps "${d:-0}") Mbps"
else
  say "FAIL: could not make $IFACE the default route (now $(default_route_if))"
fi
# cleanup (trap) puts the built-in Wi-Fi back and stops the client.
