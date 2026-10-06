# Shared helpers for Snorkel scripts. Sourced, not run.
# All functions need root except the read-only ones.

# The built-in Wi-Fi device (en1 on a Mac mini 2014).
builtin_wifi_dev() {
  networksetup -listallhardwareports |
    awk '/^Hardware Port: Wi-Fi/{getline; print $2; exit}'
}

# The dynamic-store service ID whose IPv4 state is on interface $1.
service_id_for() {
  local id
  for id in $(echo "list State:/Network/Service/[^/]+/IPv4" | scutil |
              awk '{print $4}' | cut -d/ -f4); do
    if echo "show State:/Network/Service/$id/IPv4" | scutil |
         grep -q "InterfaceName : $1\$"; then
      echo "$id"
      return 0
    fi
  done
  return 1
}

# Demote service $1 so another interface can be primary. "Last" keeps it as
# the fallback: macOS uses it again as soon as nothing else is usable.
# Undo with clear_rank. The key does not exist by default.
set_rank_last() {
  scutil <<EOF
d.init
d.add PrimaryRank Last
set State:/Network/Service/$1/__SERVICE__
EOF
}

clear_rank() {
  echo "remove State:/Network/Service/$1/__SERVICE__" | scutil
}

default_route_if() {
  route -n get default 2>/dev/null | awk '/interface:/{print $2}'
}

# The router on interface $1, from its DHCP packet.
dhcp_router() {
  ipconfig getoption "$1" router 2>/dev/null
}

# "On" or "Off" for Wi-Fi device $1.
wifi_power() {
  networksetup -getairportpower "$1" 2>/dev/null | awk '{print $NF}'
}

# Set KEY=VALUE in config file $1 (key $2, value $3), quoted for the shell;
# appended when the key is missing. Keeps the file's owner and mode.
set_conf() {
  local tmp
  tmp=$(mktemp) || return 1
  KEY="$2" LINE="$2=$(printf '%q' "$3")" awk '
    index($0, ENVIRON["KEY"] "=") == 1 { print ENVIRON["LINE"]; done = 1; next }
    { print }
    END { if (!done) print ENVIRON["LINE"] }' "$1" > "$tmp" &&
  cat "$tmp" > "$1"
  rm -f "$tmp"
}

# Store the password of network $1 in file $2, root-only: from the System
# keychain, or typed in when the keychain has none (a network this Mac never
# joined).
store_psk() {
  local psk=""
  echo "Reading the $1 password from the Keychain (approve the dialog if one shows)."
  psk="$(security find-generic-password -D 'AirPort network password' \
    -a "$1" -w /Library/Keychains/System.keychain 2>/dev/null)"
  if [ -z "$psk" ] && [ -t 0 ]; then
    read -r -s -p "Not in the Keychain. Wi-Fi password for $1: " psk
    echo
  fi
  if [ ${#psk} -lt 8 ]; then
    echo "No usable password for $1 (WPA2 needs 8 to 63 characters)."
    return 1
  fi
  ( umask 077; printf '%s' "$psk" > "$2" )
  chown root:wheel "$2"
  chmod 600 "$2"
}

# True when $1 is a channel number the radio tunes: 1-14, or 5 GHz 32-177.
valid_channel() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 14 ] && return 0
  [ "$1" -ge 32 ] && [ "$1" -le 177 ]
}
