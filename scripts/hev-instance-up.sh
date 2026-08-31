#!/bin/bash
set -euo pipefail
INSTANCE="${1:?Missing instance number}"
CONF="/etc/hev/${INSTANCE}/instance.conf"
[ -f "$CONF" ] || { echo "Missing configuration: $CONF" >&2; exit 1; }
source "$CONF"
IP_MODE="${IP_MODE:-dual}"
: "${TUN_IF:?Missing TUN_IF}" "${ROUTE_TABLE:?Missing ROUTE_TABLE}" "${RULE_PRIORITY:?Missing RULE_PRIORITY}" "${PROXY_IP:?Missing PROXY_IP}" "${LAN_IF:?Missing LAN_IF}" "${LAN_NET:?Missing LAN_NET}" "${LAN_NET6:?Missing LAN_NET6}" "${WAN_IF:?Missing WAN_IF}"
for i in $(seq 1 30); do ip link show "$TUN_IF" >/dev/null 2>&1 && break; sleep 0.5; done
ip link show "$TUN_IF" >/dev/null 2>&1 || { echo "Interface $TUN_IF was not created" >&2; exit 1; }
case "$IP_MODE" in
  ipv4)
    : "${CLIENT_IP:?Missing CLIENT_IP}" "${WAN_GW:?Missing WAN_GW}"
    ip route replace "${PROXY_IP}/32" via "$WAN_GW" dev "$WAN_IF"
    ip route replace "$LAN_NET" dev "$LAN_IF" table "$ROUTE_TABLE"
    ip route replace default dev "$TUN_IF" table "$ROUTE_TABLE"
    while ip rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done
    ip rule add priority "$RULE_PRIORITY" from "${CLIENT_IP}/32" lookup "$ROUTE_TABLE"
    while ip -6 rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done
    ip6tables -C FORWARD -s "${CLIENT_IP}/32" -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT 2>/dev/null || true
    iptables -C FORWARD -s "${CLIENT_IP}/32" -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -s "${CLIENT_IP}/32" -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT
    iptables -C FORWARD -d "${CLIENT_IP}/32" -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -d "${CLIENT_IP}/32" -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -C FORWARD -s "${CLIENT_IP}/32" -i "$LAN_IF" -o "$WAN_IF" -j REJECT 2>/dev/null || iptables -A FORWARD -s "${CLIENT_IP}/32" -i "$LAN_IF" -o "$WAN_IF" -j REJECT
    ;;
  ipv6)
    : "${CLIENT_IPV6:?Missing CLIENT_IPV6}"
    ip -6 route get "$PROXY_IP" >/dev/null
    ip -6 route replace "$LAN_NET6" dev "$LAN_IF" table "$ROUTE_TABLE"
    ip -6 route replace default dev "$TUN_IF" table "$ROUTE_TABLE"
    while ip -6 rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done
    ip -6 rule add priority "$RULE_PRIORITY" from "${CLIENT_IPV6}/128" lookup "$ROUTE_TABLE"
    while ip rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done
    ip6tables -C FORWARD -s "${CLIENT_IPV6}/128" -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT 2>/dev/null || ip6tables -I FORWARD 1 -s "${CLIENT_IPV6}/128" -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT
    ip6tables -C FORWARD -d "${CLIENT_IPV6}/128" -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || ip6tables -I FORWARD 1 -d "${CLIENT_IPV6}/128" -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -C FORWARD -s "${CLIENT_IPV6}/128" -i "$LAN_IF" -o "$WAN_IF" -j REJECT 2>/dev/null || ip6tables -A FORWARD -s "${CLIENT_IPV6}/128" -i "$LAN_IF" -o "$WAN_IF" -j REJECT
    ;;
  *) echo "Unsupported IP_MODE: $IP_MODE" >&2; exit 1 ;;
esac
ip route flush cache 2>/dev/null || true
ip -6 route flush cache 2>/dev/null || true
