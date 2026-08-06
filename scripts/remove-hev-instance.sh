#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: sudo $0 INSTANCE"
    echo "Example: sudo $0 104"
    exit 1
fi

INSTANCE="$1"

if ! [[ "$INSTANCE" =~ ^[0-9]+$ ]] ||
   [ "$INSTANCE" -lt 101 ] ||
   [ "$INSTANCE" -gt 120 ]; then
    echo "ERROR: INSTANCE must be between 101 and 120." >&2
    exit 1
fi

INSTANCE_DIR="/etc/hev/${INSTANCE}"
INSTANCE_CONF="${INSTANCE_DIR}/instance.conf"
SERVICE="hev-socks5-tunnel@${INSTANCE}.service"
TABLE_ID="$((INSTANCE + 100))"

if [ ! -d "$INSTANCE_DIR" ]; then
    echo "ERROR: Instance ${INSTANCE} does not exist: ${INSTANCE_DIR}" >&2
    exit 1
fi

# Defaults match add-hev-instance.sh. Existing instance.conf may override them.
CLIENT_IP="10.0.1.${INSTANCE}"
TUN_IF="hev${INSTANCE}"
ROUTE_TABLE="hev${INSTANCE}"
RULE_PRIORITY="$((INSTANCE + 900))"
LAN_IF="enp1s0"
WAN_IF="wlp2s0"

if [ -f "$INSTANCE_CONF" ]; then
    # shellcheck disable=SC1090
    source "$INSTANCE_CONF"
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/hev-removed-${INSTANCE}-${TIMESTAMP}"

mkdir -p "$BACKUP_DIR"
cp -a "$INSTANCE_DIR" "$BACKUP_DIR/"

systemctl disable --now "$SERVICE" 2>/dev/null || true

while ip rule del priority "$RULE_PRIORITY" 2>/dev/null; do
    :
done

ip route flush table "$ROUTE_TABLE" 2>/dev/null || true
ip route flush cache

while iptables -C FORWARD \
    -s "${CLIENT_IP}/32" -i "$LAN_IF" -o "$TUN_IF" \
    -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD \
        -s "${CLIENT_IP}/32" -i "$LAN_IF" -o "$TUN_IF" \
        -j ACCEPT
done

while iptables -C FORWARD \
    -d "${CLIENT_IP}/32" -i "$TUN_IF" -o "$LAN_IF" \
    -m conntrack --ctstate ESTABLISHED,RELATED \
    -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD \
        -d "${CLIENT_IP}/32" -i "$TUN_IF" -o "$LAN_IF" \
        -m conntrack --ctstate ESTABLISHED,RELATED \
        -j ACCEPT
done

while iptables -C FORWARD \
    -s "${CLIENT_IP}/32" -i "$LAN_IF" -o "$WAN_IF" \
    -j REJECT 2>/dev/null; do
    iptables -D FORWARD \
        -s "${CLIENT_IP}/32" -i "$LAN_IF" -o "$WAN_IF" \
        -j REJECT
done

ip link delete "$TUN_IF" 2>/dev/null || true

sed -i -E \
    "/^[[:space:]]*${TABLE_ID}[[:space:]]+${ROUTE_TABLE}[[:space:]]*$/d" \
    /etc/iproute2/rt_tables

rm -rf "$INSTANCE_DIR"

systemctl daemon-reload
systemctl reset-failed "$SERVICE" 2>/dev/null || true

echo
echo "Removed HEV instance ${INSTANCE}."
echo "Backup: ${BACKUP_DIR}"
echo "Service: ${SERVICE}"
echo "Tunnel: ${TUN_IF}"
echo "Routing table: ${ROUTE_TABLE} (${TABLE_ID})"
