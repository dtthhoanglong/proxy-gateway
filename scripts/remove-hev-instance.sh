#!/bin/bash
set -euo pipefail

NETWORK_CONF="/etc/proxy-gateway/network.conf"

if [ ! -f "$NETWORK_CONF" ]; then
    echo "ERROR: Missing network configuration: $NETWORK_CONF" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$NETWORK_CONF"

: "${LAN_IF:?Missing LAN_IF}"
: "${WAN_IF:?Missing WAN_IF}"
: "${LAN_IP:?Missing LAN_IP}"
: "${LAN_NET:?Missing LAN_NET}"
: "${WAN_GW:?Missing WAN_GW}"

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
DNS_SERVICE="proxy-gateway-dns@${INSTANCE}.service"

TABLE_ID="$((INSTANCE + 100))"

DHCP_CONFIG="/etc/dhcp/dhcpd.conf"
DHCP_HOST="vm${INSTANCE}"
DHCP_BACKUP=""
DHCP_CHANGED=0
TEMP_DHCP=""

DNS_CONFIG="/etc/unbound/proxy-gateway/vm${INSTANCE}.conf"

if [ ! -d "$INSTANCE_DIR" ]; then
    echo "ERROR: Instance ${INSTANCE} does not exist: ${INSTANCE_DIR}" >&2
    exit 1
fi

# Defaults for compatibility with older instances.
CLIENT_IP="10.0.1.${INSTANCE}"
TUN_IF="hev${INSTANCE}"
ROUTE_TABLE="hev${INSTANCE}"
RULE_PRIORITY="$((INSTANCE + 900))"

DNS_SOURCE_IP="198.19.${INSTANCE}.1"
DNS_PORT="$((53000 + INSTANCE))"
DNS_RULE_PRIORITY="$((INSTANCE + 1000))"
DNS_BLOCK_PRIORITY="$((INSTANCE + 1100))"


if [ -f "$INSTANCE_CONF" ]; then
    # shellcheck disable=SC1090
    source "$INSTANCE_CONF"
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/hev-removed-${INSTANCE}-${TIMESTAMP}"

mkdir -p "$BACKUP_DIR"

cp -a "$INSTANCE_DIR" "$BACKUP_DIR/"

if [ -f "$DNS_CONFIG" ]; then
    cp -a "$DNS_CONFIG" "$BACKUP_DIR/"
fi

restore_dhcp() {
    rm -f "${TEMP_DHCP:-}"

    if [ "$DHCP_CHANGED" -eq 1 ] &&
       [ -n "$DHCP_BACKUP" ] &&
       [ -f "$DHCP_BACKUP" ]; then

        echo "Restoring previous DHCP configuration..." >&2

        cp -a "$DHCP_BACKUP" "$DHCP_CONFIG"

        systemctl restart isc-dhcp-server 2>/dev/null || true
    fi
}

trap restore_dhcp ERR

#
# Remove DHCP reservation.
#

if [ -f "$DHCP_CONFIG" ]; then
    DHCP_BACKUP="${DHCP_CONFIG}.bak-${TIMESTAMP}"
    TEMP_DHCP="$(mktemp)"

    cp -a "$DHCP_CONFIG" "$DHCP_BACKUP"

    python3 - "$DHCP_CONFIG" "$TEMP_DHCP" "$DHCP_HOST" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
host_name = sys.argv[3]

text = source.read_text()

pattern = re.compile(
    rf"(?ms)^[ \t]*host[ \t]+{re.escape(host_name)}[ \t]*\{{"
    rf".*?^[ \t]*\}}[ \t]*\n?"
)

updated, count = pattern.subn("", text)

if count > 1:
    raise SystemExit(
        f"Found more than one DHCP reservation for {host_name}"
    )

target.write_text(updated.rstrip() + "\n")
PY

    install -o root -g root -m 644 \
        "$TEMP_DHCP" \
        "$DHCP_CONFIG"

    DHCP_CHANGED=1

    rm -f "$TEMP_DHCP"
    TEMP_DHCP=""

    dhcpd -t -4 -cf "$DHCP_CONFIG"

    systemctl restart isc-dhcp-server

    sleep 1

    if ! systemctl is-active --quiet isc-dhcp-server; then
        echo \
            "ERROR: isc-dhcp-server is not active after removing reservation." \
            >&2
        false
    fi
fi

#
# Stop services.
#

systemctl disable --now "$DNS_SERVICE" 2>/dev/null || true
systemctl disable --now "$SERVICE" 2>/dev/null || true

#
# Remove DNS policy routing.
#

while ip rule del priority "$DNS_RULE_PRIORITY" 2>/dev/null; do
    :
done

while ip rule del priority "$DNS_BLOCK_PRIORITY" 2>/dev/null; do
    :
done

#
# Remove VM policy routing.
#

while ip rule del priority "$RULE_PRIORITY" 2>/dev/null; do
    :
done

#
# Remove per-VM DNS redirect.
#

while iptables -t nat -C PREROUTING \
    -i "$LAN_IF" \
    -s "${CLIENT_IP}/32" \
    -d "$LAN_IP" \
    -p udp \
    --dport 53 \
    -j REDIRECT \
    --to-ports "$DNS_PORT" 2>/dev/null; do

    iptables -t nat -D PREROUTING \
        -i "$LAN_IF" \
        -s "${CLIENT_IP}/32" \
        -d "$LAN_IP" \
        -p udp \
        --dport 53 \
        -j REDIRECT \
        --to-ports "$DNS_PORT"
done

while iptables -t nat -C PREROUTING \
    -i "$LAN_IF" \
    -s "${CLIENT_IP}/32" \
    -d "$LAN_IP" \
    -p tcp \
    --dport 53 \
    -j REDIRECT \
    --to-ports "$DNS_PORT" 2>/dev/null; do

    iptables -t nat -D PREROUTING \
        -i "$LAN_IF" \
        -s "${CLIENT_IP}/32" \
        -d "$LAN_IP" \
        -p tcp \
        --dport 53 \
        -j REDIRECT \
        --to-ports "$DNS_PORT"
done

#
# Remove DNS source address.
#

ip addr del "${DNS_SOURCE_IP}/32" dev lo \
    2>/dev/null || true

#
# Remove HEV routing state.
#

ip route flush table "$ROUTE_TABLE" \
    2>/dev/null || true

ip route flush cache

#
# Remove FORWARD rules.
#

while iptables -C FORWARD \
    -s "${CLIENT_IP}/32" \
    -i "$LAN_IF" \
    -o "$TUN_IF" \
    -j ACCEPT 2>/dev/null; do

    iptables -D FORWARD \
        -s "${CLIENT_IP}/32" \
        -i "$LAN_IF" \
        -o "$TUN_IF" \
        -j ACCEPT
done

while iptables -C FORWARD \
    -d "${CLIENT_IP}/32" \
    -i "$TUN_IF" \
    -o "$LAN_IF" \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT 2>/dev/null; do

    iptables -D FORWARD \
        -d "${CLIENT_IP}/32" \
        -i "$TUN_IF" \
        -o "$LAN_IF" \
        -m conntrack \
        --ctstate ESTABLISHED,RELATED \
        -j ACCEPT
done

while iptables -C FORWARD \
    -s "${CLIENT_IP}/32" \
    -i "$LAN_IF" \
    -o "$WAN_IF" \
    -j REJECT 2>/dev/null; do

    iptables -D FORWARD \
        -s "${CLIENT_IP}/32" \
        -i "$LAN_IF" \
        -o "$WAN_IF" \
        -j REJECT
done

#
# Remove tunnel if still present.
#

ip link delete "$TUN_IF" \
    2>/dev/null || true

#
# Remove routing-table registration.
#

sed -i -E \
    "/^[[:space:]]*${TABLE_ID}[[:space:]]+${ROUTE_TABLE}[[:space:]]*$/d" \
    /etc/iproute2/rt_tables

#
# Remove persistent configuration.
#

rm -f "$DNS_CONFIG"
rm -rf "$INSTANCE_DIR"

systemctl daemon-reload

systemctl reset-failed "$SERVICE" \
    2>/dev/null || true

systemctl reset-failed "$DNS_SERVICE" \
    2>/dev/null || true

trap - ERR

if [ -x /usr/local/sbin/cleanup-hev-backups.sh ]; then
    /usr/local/sbin/cleanup-hev-backups.sh || true
fi

echo
echo "Removed Proxy Gateway instance ${INSTANCE}."
echo "Removed DHCP reservation: ${DHCP_HOST}"
echo "Removed DNS service: ${DNS_SERVICE}"
echo "Removed DNS source IP: ${DNS_SOURCE_IP}"
echo "Removed DNS redirect port: ${DNS_PORT}"
echo "Backup: ${BACKUP_DIR}"
echo "HEV service: ${SERVICE}"
echo "Tunnel: ${TUN_IF}"
echo "Routing table: ${ROUTE_TABLE} (${TABLE_ID})"
