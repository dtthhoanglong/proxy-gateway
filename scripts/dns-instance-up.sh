#!/bin/bash
set -euo pipefail

INSTANCE="${1:?Missing instance number}"
CONF="/etc/hev/${INSTANCE}/instance.conf"

[ -f "$CONF" ] || {
    echo "Missing configuration: $CONF" >&2
    exit 1
}

source "$CONF"

IP_MODE="${IP_MODE:-ipv4}"

: "${LAN_IF:?Missing LAN_IF}"
: "${LAN_IP:?Missing LAN_IP}"
: "${LAN_IPV6:?Missing LAN_IPV6}"
: "${ROUTE_TABLE:?Missing ROUTE_TABLE}"
: "${DNS_PORT:?Missing DNS_PORT}"
: "${DNS_RULE_PRIORITY:?Missing DNS_RULE_PRIORITY}"
: "${DNS_BLOCK_PRIORITY:?Missing DNS_BLOCK_PRIORITY}"

case "$IP_MODE" in
  ipv4)
    : "${CLIENT_IP:?Missing CLIENT_IP}"
    : "${DNS_SOURCE_IP:?Missing DNS_SOURCE_IP}"

    if ! ip addr show dev lo | grep -Fq " ${DNS_SOURCE_IP}/32 "; then
        ip addr add "${DNS_SOURCE_IP}/32" dev lo
    fi

    while ip rule del priority "$DNS_RULE_PRIORITY" 2>/dev/null; do :; done
    while ip rule del priority "$DNS_BLOCK_PRIORITY" 2>/dev/null; do :; done

    ip rule add priority "$DNS_RULE_PRIORITY" from "${DNS_SOURCE_IP}/32" lookup "$ROUTE_TABLE"
    ip rule add priority "$DNS_BLOCK_PRIORITY" from "${DNS_SOURCE_IP}/32" unreachable

    for proto in udp tcp; do
      iptables -t nat -C PREROUTING -i "$LAN_IF" -s "${CLIENT_IP}/32" -d "$LAN_IP" -p "$proto" --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null ||
      iptables -t nat -I PREROUTING 1 -i "$LAN_IF" -s "${CLIENT_IP}/32" -d "$LAN_IP" -p "$proto" --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
    done
    ;;

  ipv6)
    : "${CLIENT_IPV6:?Missing CLIENT_IPV6}"
    DNS_SOURCE_IPV6="${DNS_SOURCE_IPV6:-fd19::${INSTANCE}}"

    if ! ip -6 addr show dev lo | grep -Fq " ${DNS_SOURCE_IPV6}/128 "; then
        ip -6 addr add "${DNS_SOURCE_IPV6}/128" dev lo
    fi

    while ip -6 rule del priority "$DNS_RULE_PRIORITY" 2>/dev/null; do :; done
    while ip -6 rule del priority "$DNS_BLOCK_PRIORITY" 2>/dev/null; do :; done

    ip -6 rule add priority "$DNS_RULE_PRIORITY" from "${DNS_SOURCE_IPV6}/128" lookup "$ROUTE_TABLE"
    ip -6 rule add priority "$DNS_BLOCK_PRIORITY" from "${DNS_SOURCE_IPV6}/128" unreachable

    for proto in udp tcp; do
      ip6tables -t nat -C PREROUTING -i "$LAN_IF" -s "${CLIENT_IPV6}/128" -d "${LAN_IPV6}/128" -p "$proto" --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null ||
      ip6tables -t nat -I PREROUTING 1 -i "$LAN_IF" -s "${CLIENT_IPV6}/128" -d "${LAN_IPV6}/128" -p "$proto" --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
    done
    ;;

  *)
    echo "Unsupported IP_MODE: $IP_MODE" >&2
    exit 1
    ;;
esac

ip route flush cache
ip -6 route flush cache 2>/dev/null || true
