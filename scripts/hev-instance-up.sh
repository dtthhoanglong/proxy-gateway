#!/bin/bash
set -euo pipefail

INSTANCE="${1:?Missing instance number}"
CONF="/etc/hev/${INSTANCE}/instance.conf"
[ -f "$CONF" ] || { echo "Missing configuration: $CONF" >&2; exit 1; }
source "$CONF"

IP_MODE="${IP_MODE:-dual}"
MARK_CHAIN="PGW6M${INSTANCE}"
FWD_CHAIN="PGW6F${INSTANCE}"
MARK_VALUE="${INSTANCE}"

: "${TUN_IF:?Missing TUN_IF}" "${ROUTE_TABLE:?Missing ROUTE_TABLE}" "${RULE_PRIORITY:?Missing RULE_PRIORITY}" "${PROXY_IP:?Missing PROXY_IP}" "${LAN_IF:?Missing LAN_IF}" "${LAN_NET:?Missing LAN_NET}" "${LAN_NET6:?Missing LAN_NET6}" "${WAN_IF:?Missing WAN_IF}"

for i in $(seq 1 30); do
    ip link show "$TUN_IF" >/dev/null 2>&1 && break
    sleep 0.5
done
ip link show "$TUN_IF" >/dev/null 2>&1 || { echo "Interface $TUN_IF was not created" >&2; exit 1; }

cleanup_ipv6_mac_policy() {
    while ip6tables -t mangle -C PREROUTING -i "$LAN_IF" -j "$MARK_CHAIN" 2>/dev/null; do
        ip6tables -t mangle -D PREROUTING -i "$LAN_IF" -j "$MARK_CHAIN"
    done
    ip6tables -t mangle -F "$MARK_CHAIN" 2>/dev/null || true
    ip6tables -t mangle -X "$MARK_CHAIN" 2>/dev/null || true

    while ip6tables -C FORWARD -i "$LAN_IF" -j "$FWD_CHAIN" 2>/dev/null; do
        ip6tables -D FORWARD -i "$LAN_IF" -j "$FWD_CHAIN"
    done
    ip6tables -F "$FWD_CHAIN" 2>/dev/null || true
    ip6tables -X "$FWD_CHAIN" 2>/dev/null || true

    while ip6tables -C FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do
        ip6tables -D FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    done
}

case "$IP_MODE" in
  ipv4)
    : "${CLIENT_IP:?Missing CLIENT_IP}" "${WAN_GW:?Missing WAN_GW}"
    cleanup_ipv6_mac_policy
    while ip -6 rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done

    ip route replace "${PROXY_IP}/32" via "$WAN_GW" dev "$WAN_IF"
    ip route replace "$LAN_NET" dev "$LAN_IF" table "$ROUTE_TABLE"
    ip route replace default dev "$TUN_IF" table "$ROUTE_TABLE"
    while ip rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done
    ip rule add priority "$RULE_PRIORITY" from "${CLIENT_IP}/32" lookup "$ROUTE_TABLE"

    iptables -C FORWARD -s "${CLIENT_IP}/32" -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -s "${CLIENT_IP}/32" -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT
    iptables -C FORWARD -d "${CLIENT_IP}/32" -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -d "${CLIENT_IP}/32" -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -C FORWARD -s "${CLIENT_IP}/32" -i "$LAN_IF" -o "$WAN_IF" -j REJECT 2>/dev/null || iptables -A FORWARD -s "${CLIENT_IP}/32" -i "$LAN_IF" -o "$WAN_IF" -j REJECT
    ;;

  ipv6)
    ip -6 route get "$PROXY_IP" >/dev/null
    ip -6 route replace "$LAN_NET6" dev "$LAN_IF" table "$ROUTE_TABLE"
    ip -6 route replace default dev "$TUN_IF" table "$ROUTE_TABLE"

    while ip -6 rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done
    while ip -6 rule del fwmark "$MARK_VALUE" lookup "$ROUTE_TABLE" 2>/dev/null; do :; done
    while ip rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done

    if [ -n "${CLIENT_IPV6:-}" ]; then
        while ip6tables -C FORWARD -s "${CLIENT_IPV6}/128" -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT 2>/dev/null; do
            ip6tables -D FORWARD -s "${CLIENT_IPV6}/128" -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT
        done
        while ip6tables -C FORWARD -d "${CLIENT_IPV6}/128" -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do
            ip6tables -D FORWARD -d "${CLIENT_IPV6}/128" -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        done
        while ip6tables -C FORWARD -s "${CLIENT_IPV6}/128" -i "$LAN_IF" -o "$WAN_IF" -j REJECT 2>/dev/null; do
            ip6tables -D FORWARD -s "${CLIENT_IPV6}/128" -i "$LAN_IF" -o "$WAN_IF" -j REJECT
        done
    fi

    cleanup_ipv6_mac_policy

    if [ -n "${CLIENT_MAC:-}" ]; then
        CLIENT_MAC="$(printf '%s' "$CLIENT_MAC" | tr '[:upper:]' '[:lower:]' | tr '-' ':')"
        [[ "$CLIENT_MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || { echo "Invalid CLIENT_MAC: $CLIENT_MAC" >&2; exit 1; }

        while ip6tables -t mangle -C PREROUTING -i "$LAN_IF" -m mac --mac-source "$CLIENT_MAC" -j MARK --set-mark "$MARK_VALUE" 2>/dev/null; do
            ip6tables -t mangle -D PREROUTING -i "$LAN_IF" -m mac --mac-source "$CLIENT_MAC" -j MARK --set-mark "$MARK_VALUE"
        done
        while ip6tables -t mangle -C PREROUTING -i "$LAN_IF" -m mac --mac-source "$CLIENT_MAC" ! -d "$LAN_NET6" -j MARK --set-mark "$MARK_VALUE" 2>/dev/null; do
            ip6tables -t mangle -D PREROUTING -i "$LAN_IF" -m mac --mac-source "$CLIENT_MAC" ! -d "$LAN_NET6" -j MARK --set-mark "$MARK_VALUE"
        done

        ip6tables -t mangle -N "$MARK_CHAIN" 2>/dev/null || true
        ip6tables -t mangle -F "$MARK_CHAIN"
        ip6tables -t mangle -A "$MARK_CHAIN" -m mac --mac-source "$CLIENT_MAC" -d 2000::/3 -j MARK --set-mark "$MARK_VALUE"
        ip6tables -t mangle -C PREROUTING -i "$LAN_IF" -j "$MARK_CHAIN" 2>/dev/null || ip6tables -t mangle -I PREROUTING 1 -i "$LAN_IF" -j "$MARK_CHAIN"

        ip -6 rule add priority "$RULE_PRIORITY" fwmark "$MARK_VALUE" lookup "$ROUTE_TABLE"

        ip6tables -N "$FWD_CHAIN" 2>/dev/null || true
        ip6tables -F "$FWD_CHAIN"
        ip6tables -A "$FWD_CHAIN" -m mac --mac-source "$CLIENT_MAC" -o "$TUN_IF" -j ACCEPT
        ip6tables -A "$FWD_CHAIN" -m mac --mac-source "$CLIENT_MAC" -o "$WAN_IF" -j REJECT
        ip6tables -C FORWARD -i "$LAN_IF" -j "$FWD_CHAIN" 2>/dev/null || ip6tables -I FORWARD 1 -i "$LAN_IF" -j "$FWD_CHAIN"
        ip6tables -C FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || ip6tables -I FORWARD 1 -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    else
        echo "IPv6 instance ${INSTANCE}: no CLIENT_MAC yet; client policy not installed."
    fi
    ;;

  *) echo "Unsupported IP_MODE: $IP_MODE" >&2; exit 1 ;;
esac

ip route flush cache 2>/dev/null || true
ip -6 route flush cache 2>/dev/null || true
