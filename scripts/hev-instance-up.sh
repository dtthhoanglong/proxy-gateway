#!/bin/bash
set -euo pipefail

INSTANCE="${1:?Missing instance number}"
CONF="/etc/hev/${INSTANCE}/instance.conf"

if [ ! -f "$CONF" ]; then
    echo "Missing configuration: $CONF" >&2
    exit 1
fi

source "$CONF"

for i in $(seq 1 30); do
    if ip link show "$TUN_IF" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

if ! ip link show "$TUN_IF" >/dev/null 2>&1; then
    echo "Interface $TUN_IF was not created" >&2
    exit 1
fi

ip route replace "${PROXY_IP}/32" via "$WAN_GW" dev "$WAN_IF"

ip route replace "$LAN_NET" dev "$LAN_IF" table "$ROUTE_TABLE"
ip route replace default dev "$TUN_IF" table "$ROUTE_TABLE"

while ip rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done
ip rule add priority "$RULE_PRIORITY" from "${CLIENT_IP}/32" lookup "$ROUTE_TABLE"

ip route flush cache

iptables -C FORWARD -s "${CLIENT_IP}/32" -i "$LAN_IF" -o "$TUN_IF" \
    -j ACCEPT 2>/dev/null ||
iptables -I FORWARD 1 -s "${CLIENT_IP}/32" -i "$LAN_IF" -o "$TUN_IF" \
    -j ACCEPT

iptables -C FORWARD -d "${CLIENT_IP}/32" -i "$TUN_IF" -o "$LAN_IF" \
    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null ||
iptables -I FORWARD 1 -d "${CLIENT_IP}/32" -i "$TUN_IF" -o "$LAN_IF" \
    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Fail-close: không cho VM đi trực tiếp ra WAN nếu tunnel bị lỗi.
iptables -C FORWARD \
    -s "${CLIENT_IP}/32" \
    -i "$LAN_IF" \
    -o "$WAN_IF" \
    -j REJECT 2>/dev/null ||
iptables -A FORWARD \
    -s "${CLIENT_IP}/32" \
    -i "$LAN_IF" \
    -o "$WAN_IF" \
    -j REJECT

exit 0
