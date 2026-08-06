#!/bin/bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "Usage:"
    echo "  sudo $0 INSTANCE PROXY_IP PROXY_PORT USERNAME PASSWORD"
    echo
    echo "Example:"
    echo "  sudo $0 103 203.0.113.10 3903 ExampleUser3 ChangeThisPassword"
    exit 1
fi

INSTANCE="$1"
PROXY_IP="$2"
PROXY_PORT="$3"
PROXY_USER="$4"
PROXY_PASS="$5"

if ! [[ "$INSTANCE" =~ ^[0-9]+$ ]] ||
   [ "$INSTANCE" -lt 101 ] ||
   [ "$INSTANCE" -gt 120 ]; then
    echo "ERROR: INSTANCE must be between 101 and 120." >&2
    exit 1
fi

if ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] ||
   [ "$PROXY_PORT" -lt 1 ] ||
   [ "$PROXY_PORT" -gt 65535 ]; then
    echo "ERROR: Invalid proxy port." >&2
    exit 1
fi

CLIENT_IP="10.0.1.${INSTANCE}"
TUN_IF="hev${INSTANCE}"
TUN_IPV4="198.18.0.$((INSTANCE - 100))"
ROUTE_TABLE="hev${INSTANCE}"
TABLE_ID="$((INSTANCE + 100))"
RULE_PRIORITY="$((INSTANCE + 900))"

INSTANCE_DIR="/etc/hev/${INSTANCE}"
HEV_CONFIG="${INSTANCE_DIR}/config.yml"
INSTANCE_CONFIG="${INSTANCE_DIR}/instance.conf"
SERVICE="hev-socks5-tunnel@${INSTANCE}.service"
RT_TABLES="/etc/iproute2/rt_tables"

CREATED_INSTANCE=0
TABLE_ADDED=0

rollback() {
    local exit_code=$?

    trap - ERR
    echo "ERROR: Creating instance ${INSTANCE} failed. Rolling back..." >&2

    systemctl disable --now "$SERVICE" 2>/dev/null || true

    while ip rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done
    ip route flush table "$ROUTE_TABLE" 2>/dev/null || true
    ip route flush cache 2>/dev/null || true
    ip link delete "$TUN_IF" 2>/dev/null || true

    if [ "$TABLE_ADDED" -eq 1 ]; then
        sed -i -E \
            "/^[[:space:]]*${TABLE_ID}[[:space:]]+${ROUTE_TABLE}[[:space:]]*$/d" \
            "$RT_TABLES"
    fi

    if [ "$CREATED_INSTANCE" -eq 1 ]; then
        rm -rf "$INSTANCE_DIR"
    fi

    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed "$SERVICE" 2>/dev/null || true

    exit "$exit_code"
}

trap rollback ERR

if [ -e "$HEV_CONFIG" ] || [ -e "$INSTANCE_CONFIG" ]; then
    echo "ERROR: Instance ${INSTANCE} already exists in ${INSTANCE_DIR}." >&2
    exit 1
fi

command -v nc >/dev/null 2>&1 || {
    echo "ERROR: nc is not installed. Install netcat-openbsd first." >&2
    exit 1
}

echo "Checking proxy ${PROXY_IP}:${PROXY_PORT}..."

if ! nc -z -w 5 "$PROXY_IP" "$PROXY_PORT"; then
    echo "ERROR: Cannot connect to ${PROXY_IP}:${PROXY_PORT}." >&2
    exit 1
fi

mkdir -p "$INSTANCE_DIR"
CREATED_INSTANCE=1
chmod 750 "$INSTANCE_DIR"

cat > "$HEV_CONFIG" <<EOF_CONFIG
tunnel:
  name: ${TUN_IF}
  mtu: 1500
  ipv4: ${TUN_IPV4}

socks5:
  address: ${PROXY_IP}
  port: ${PROXY_PORT}
  username: ${PROXY_USER}
  password: ${PROXY_PASS}
  udp: 'udp'

misc:
  task-stack-size: 20480
  connect-timeout: 5000
  read-write-timeout: 60000
  tcp-read-write-timeout: 60000
EOF_CONFIG

cat > "$INSTANCE_CONFIG" <<EOF_INSTANCE
CLIENT_IP=${CLIENT_IP}
TUN_IF=${TUN_IF}
ROUTE_TABLE=${ROUTE_TABLE}
TABLE_ID=${TABLE_ID}
RULE_PRIORITY=${RULE_PRIORITY}
PROXY_IP=${PROXY_IP}
LAN_IF=enp1s0
LAN_NET=10.0.1.0/24
WAN_IF=wlp2s0
WAN_GW=192.168.2.1
EOF_INSTANCE

chmod 600 "$HEV_CONFIG" "$INSTANCE_CONFIG"

if ! grep -Eq "^[[:space:]]*${TABLE_ID}[[:space:]]+${ROUTE_TABLE}[[:space:]]*$" \
    "$RT_TABLES"; then
    echo "${TABLE_ID} ${ROUTE_TABLE}" >> "$RT_TABLES"
    TABLE_ADDED=1
fi

systemctl daemon-reload
systemctl enable --now "$SERVICE"

sleep 2

if ! systemctl is-active --quiet "$SERVICE"; then
    echo "ERROR: ${SERVICE} failed to start." >&2
    systemctl status "$SERVICE" --no-pager -l || true
    false
fi

trap - ERR

echo
echo "Instance ${INSTANCE} created successfully."
echo "Client IP:     ${CLIENT_IP}"
echo "Tunnel:        ${TUN_IF}"
echo "Tunnel IP:     ${TUN_IPV4}"
echo "Routing table: ${ROUTE_TABLE} (${TABLE_ID})"
echo "Service:       ${SERVICE}"
echo "Proxy:         ${PROXY_IP}:${PROXY_PORT}"
