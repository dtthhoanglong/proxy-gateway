#!/bin/bash
set -euo pipefail

INSTANCE="${1:?Missing instance number}"
CONF="/etc/hev/${INSTANCE}/instance.conf"

if [ ! -f "$CONF" ]; then
    echo "Missing configuration: $CONF" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONF"

: "${CLIENT_IP:?Missing CLIENT_IP}"
: "${LAN_IF:?Missing LAN_IF}"
: "${ROUTE_TABLE:?Missing ROUTE_TABLE}"
: "${DNS_SOURCE_IP:?Missing DNS_SOURCE_IP}"
: "${DNS_PORT:?Missing DNS_PORT}"
: "${DNS_RULE_PRIORITY:?Missing DNS_RULE_PRIORITY}"
: "${DNS_BLOCK_PRIORITY:?Missing DNS_BLOCK_PRIORITY}"

# DNS source address used by the per-VM Unbound instance.
if ! ip addr show dev lo | grep -Fq " ${DNS_SOURCE_IP}/32 "; then
    ip addr add "${DNS_SOURCE_IP}/32" dev lo
fi

# Remove stale rules from previous starts.
while ip rule del priority "$DNS_RULE_PRIORITY" 2>/dev/null; do
    :
done

while ip rule del priority "$DNS_BLOCK_PRIORITY" 2>/dev/null; do
    :
done

# First attempt to use the VM's HEV routing table.
ip rule add \
    priority "$DNS_RULE_PRIORITY" \
    from "${DNS_SOURCE_IP}/32" \
    lookup "$ROUTE_TABLE"

# Critical fail-close rule.
# If the HEV table has no usable route, DNS must never fall through
# to the main routing table / WAN.
ip rule add \
    priority "$DNS_BLOCK_PRIORITY" \
    from "${DNS_SOURCE_IP}/32" \
    unreachable

ip route flush cache

# Redirect only this VM's DNS traffic to its dedicated Unbound port.
iptables -t nat -C PREROUTING \
    -i "$LAN_IF" \
    -s "${CLIENT_IP}/32" \
    -d 10.0.1.1 \
    -p udp \
    --dport 53 \
    -j REDIRECT \
    --to-ports "$DNS_PORT" 2>/dev/null ||
iptables -t nat -I PREROUTING 1 \
    -i "$LAN_IF" \
    -s "${CLIENT_IP}/32" \
    -d 10.0.1.1 \
    -p udp \
    --dport 53 \
    -j REDIRECT \
    --to-ports "$DNS_PORT"

iptables -t nat -C PREROUTING \
    -i "$LAN_IF" \
    -s "${CLIENT_IP}/32" \
    -d 10.0.1.1 \
    -p tcp \
    --dport 53 \
    -j REDIRECT \
    --to-ports "$DNS_PORT" 2>/dev/null ||
iptables -t nat -I PREROUTING 1 \
    -i "$LAN_IF" \
    -s "${CLIENT_IP}/32" \
    -d 10.0.1.1 \
    -p tcp \
    --dport 53 \
    -j REDIRECT \
    --to-ports "$DNS_PORT"

exit 0
