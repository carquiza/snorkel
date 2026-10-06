# Shared helpers for the devourer station scripts. Sourced, not run.
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
