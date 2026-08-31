#!/bin/bash
set -euo pipefail

INSTANCE="${1:?Missing instance number}"
CONF="/etc/hev/${INSTANCE}/instance.conf"
[ -f "$CONF" ] || { echo "Missing configuration: $CONF" >&2; exit 1; }
source "$CONF"

IP_MODE="${IP_MODE:-ipv4}"
DNS_CHAIN="PGW6D${INSTANCE}"

: "${LAN_IF:?Missing LAN_IF}"
: "${LAN_IP:?Missing LAN_IP}"
: "${LAN_IPV6:?Missing LAN_IPV6}"
: "${ROUTE_TABLE:?Missing ROUTE_TABLE}"
: "${DNS_PORT:?Missing DNS_PORT}"
: "${DNS_RULE_PRIORITY:?Missing DNS_RULE_PRIORITY}"
: "${DNS_BLOCK_PRIORITY:?Missing DNS_BLOCK_PRIORITY}"

wait_for_lan_address() {
    local mode="$1"
    local i

    for i in $(seq 1 15); do
        if [ "$mode" = "ipv6" ]; then
            if ip -6 addr show dev "$LAN_IF" scope global 2>/dev/null |
               grep -F " ${LAN_IPV6}/" |
               grep -qv tentative; then
                return 0
            fi
        else
            if ip -4 addr show dev "$LAN_IF" 2>/dev/null |
               grep -Fq " ${LAN_IP}/"; then
                return 0
            fi
        fi

        sleep 1
    done

    echo "ERROR: LAN address for ${mode} is not ready on ${LAN_IF}." >&2
    return 1
}

wait_for_lan_address "$IP_MODE"

cleanup_ipv6_dns_chain() {
    while ip6tables -t nat -C PREROUTING -i "$LAN_IF" -j "$DNS_CHAIN" 2>/dev/null; do
        ip6tables -t nat -D PREROUTING -i "$LAN_IF" -j "$DNS_CHAIN"
    done
    ip6tables -t nat -F "$DNS_CHAIN" 2>/dev/null || true
    ip6tables -t nat -X "$DNS_CHAIN" 2>/dev/null || true
}

case "$IP_MODE" in
  ipv4)
    : "${CLIENT_IP:?Missing CLIENT_IP}" "${DNS_SOURCE_IP:?Missing DNS_SOURCE_IP}"
    cleanup_ipv6_dns_chain
    if ! ip addr show dev lo | grep -Fq " ${DNS_SOURCE_IP}/32 "; then ip addr add "${DNS_SOURCE_IP}/32" dev lo; fi
    while ip rule del priority "$DNS_RULE_PRIORITY" 2>/dev/null; do :; done
    while ip rule del priority "$DNS_BLOCK_PRIORITY" 2>/dev/null; do :; done
    while ip -6 rule del priority "$DNS_RULE_PRIORITY" 2>/dev/null; do :; done
    while ip -6 rule del priority "$DNS_BLOCK_PRIORITY" 2>/dev/null; do :; done
    ip rule add priority "$DNS_RULE_PRIORITY" from "${DNS_SOURCE_IP}/32" lookup "$ROUTE_TABLE"
    ip rule add priority "$DNS_BLOCK_PRIORITY" from "${DNS_SOURCE_IP}/32" unreachable
    for proto in udp tcp; do
        iptables -t nat -C PREROUTING -i "$LAN_IF" -s "${CLIENT_IP}/32" -d "$LAN_IP" -p "$proto" --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null || iptables -t nat -I PREROUTING 1 -i "$LAN_IF" -s "${CLIENT_IP}/32" -d "$LAN_IP" -p "$proto" --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
    done
    ;;

  ipv6)
    DNS_SOURCE_IPV6="${DNS_SOURCE_IPV6:-fd19::${INSTANCE}}"
    if ! ip -6 addr show dev lo | grep -Fq " ${DNS_SOURCE_IPV6}/128 "; then ip -6 addr add "${DNS_SOURCE_IPV6}/128" dev lo; fi
    while ip -6 rule del priority "$DNS_RULE_PRIORITY" 2>/dev/null; do :; done
    while ip -6 rule del priority "$DNS_BLOCK_PRIORITY" 2>/dev/null; do :; done
    ip -6 rule add priority "$DNS_RULE_PRIORITY" from "${DNS_SOURCE_IPV6}/128" lookup "$ROUTE_TABLE"
    ip -6 rule add priority "$DNS_BLOCK_PRIORITY" from "${DNS_SOURCE_IPV6}/128" unreachable

    if [ -n "${CLIENT_IPV6:-}" ]; then
        for proto in udp tcp; do
            while ip6tables -t nat -C PREROUTING -i "$LAN_IF" -s "${CLIENT_IPV6}/128" -d "${LAN_IPV6}/128" -p "$proto" --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null; do
                ip6tables -t nat -D PREROUTING -i "$LAN_IF" -s "${CLIENT_IPV6}/128" -d "${LAN_IPV6}/128" -p "$proto" --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
            done
        done
    fi

    cleanup_ipv6_dns_chain

    if [ -n "${CLIENT_MAC:-}" ]; then
        CLIENT_MAC="$(printf '%s' "$CLIENT_MAC" | tr '[:upper:]' '[:lower:]' | tr '-' ':')"
        [[ "$CLIENT_MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || { echo "Invalid CLIENT_MAC: $CLIENT_MAC" >&2; exit 1; }

        for proto in udp tcp; do
            while ip6tables -t nat -C PREROUTING -i "$LAN_IF" -m mac --mac-source "$CLIENT_MAC" -d "${LAN_IPV6}/128" -p "$proto" --dport 53 -j DNAT --to-destination "[${LAN_IPV6}]:${DNS_PORT}" 2>/dev/null; do
                ip6tables -t nat -D PREROUTING -i "$LAN_IF" -m mac --mac-source "$CLIENT_MAC" -d "${LAN_IPV6}/128" -p "$proto" --dport 53 -j DNAT --to-destination "[${LAN_IPV6}]:${DNS_PORT}"
            done
        done

        while ip6tables -C INPUT -i "$LAN_IF" -s "${LAN_NET6:-fd10:0:1::/64}" -p udp --dport "$DNS_PORT" -j ACCEPT 2>/dev/null; do
            ip6tables -D INPUT -i "$LAN_IF" -s "${LAN_NET6:-fd10:0:1::/64}" -p udp --dport "$DNS_PORT" -j ACCEPT
        done

        ip6tables -t nat -N "$DNS_CHAIN" 2>/dev/null || true
        ip6tables -t nat -F "$DNS_CHAIN"
        ip6tables -t nat -A "$DNS_CHAIN" -m mac --mac-source "$CLIENT_MAC" -d "${LAN_IPV6}/128" -p udp --dport 53 -j DNAT --to-destination "[${LAN_IPV6}]:${DNS_PORT}"
        ip6tables -t nat -A "$DNS_CHAIN" -m mac --mac-source "$CLIENT_MAC" -d "${LAN_IPV6}/128" -p tcp --dport 53 -j DNAT --to-destination "[${LAN_IPV6}]:${DNS_PORT}"
        ip6tables -t nat -C PREROUTING -i "$LAN_IF" -j "$DNS_CHAIN" 2>/dev/null || ip6tables -t nat -I PREROUTING 1 -i "$LAN_IF" -j "$DNS_CHAIN"
    else
        echo "IPv6 instance ${INSTANCE}: no CLIENT_MAC yet; DNS client DNAT not installed."
    fi
    ;;

  *) echo "Unsupported IP_MODE: $IP_MODE" >&2; exit 1 ;;
esac

ip route flush cache 2>/dev/null || true
ip -6 route flush cache 2>/dev/null || true
