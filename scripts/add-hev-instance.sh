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
: "${LAN_IPV6:?Missing LAN_IPV6}"
: "${LAN_NET6:?Missing LAN_NET6}"
: "${WAN_GW:?Missing WAN_GW}"


if [ "$#" -ne 6 ]; then
    echo "Usage:"
    echo "  sudo $0 INSTANCE IP_MODE PROXY_IP PROXY_PORT USERNAME PASSWORD"
    echo "  IP_MODE: ipv4 or ipv6"
    exit 1
fi

INSTANCE="$1"
IP_MODE="$2"
PROXY_IP="$3"
PROXY_PORT="$4"
PROXY_USER="$5"
PROXY_PASS="$6"

case "$IP_MODE" in
    ipv4|ipv6) ;;
    *) echo "ERROR: IP_MODE must be ipv4 or ipv6." >&2; exit 1 ;;
esac

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
CLIENT_IPV6="fd10:0:1::${INSTANCE}"

TUN_IF="hev${INSTANCE}"
TUN_IPV4="198.18.0.$((INSTANCE - 100))"
TUN_IPV6="fd18::${INSTANCE}"

ROUTE_TABLE="hev${INSTANCE}"
TABLE_ID="$((INSTANCE + 100))"
RULE_PRIORITY="$((INSTANCE + 900))"

# Per-VM DNS isolation.
DNS_SOURCE_IP="198.19.${INSTANCE}.1"
DNS_SOURCE_IPV6="fd19::${INSTANCE}"
DNS_PORT="$((53000 + INSTANCE))"
DNS_RULE_PRIORITY="$((INSTANCE + 1000))"
DNS_BLOCK_PRIORITY="$((INSTANCE + 1100))"

INSTANCE_DIR="/etc/hev/${INSTANCE}"
HEV_CONFIG="${INSTANCE_DIR}/config.yml"
INSTANCE_CONFIG="${INSTANCE_DIR}/instance.conf"

DNS_CONFIG_DIR="/etc/unbound/proxy-gateway"
DNS_CONFIG="${DNS_CONFIG_DIR}/vm${INSTANCE}.conf"

SERVICE="hev-socks5-tunnel@${INSTANCE}.service"
DNS_SERVICE="proxy-gateway-dns@${INSTANCE}.service"

RT_TABLES="/etc/iproute2/rt_tables"

CREATED_INSTANCE=0
CREATED_DNS_CONFIG=0
TABLE_ADDED=0

rollback() {
    local exit_code=$?

    trap - ERR

    echo "ERROR: Creating instance ${INSTANCE} failed. Rolling back..." >&2

    systemctl disable --now "$DNS_SERVICE" 2>/dev/null || true
    systemctl disable --now "$SERVICE" 2>/dev/null || true

    while ip rule del priority "$DNS_RULE_PRIORITY" 2>/dev/null; do :; done
    while ip rule del priority "$DNS_BLOCK_PRIORITY" 2>/dev/null; do :; done
    while ip rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done
    while ip -6 rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done

    # Remove IPv4 forwarding/fail-close rules that may have been
    # installed by hev-instance-up.sh before a later step failed.
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
        -m conntrack --ctstate ESTABLISHED,RELATED \
        -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD \
            -d "${CLIENT_IP}/32" \
            -i "$TUN_IF" \
            -o "$LAN_IF" \
            -m conntrack --ctstate ESTABLISHED,RELATED \
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

    # Remove IPv6 forwarding/fail-close rules.
    while ip6tables -C FORWARD \
        -s "${CLIENT_IPV6}/128" \
        -i "$LAN_IF" \
        -o "$TUN_IF" \
        -j ACCEPT 2>/dev/null; do
        ip6tables -D FORWARD \
            -s "${CLIENT_IPV6}/128" \
            -i "$LAN_IF" \
            -o "$TUN_IF" \
            -j ACCEPT
    done

    while ip6tables -C FORWARD \
        -d "${CLIENT_IPV6}/128" \
        -i "$TUN_IF" \
        -o "$LAN_IF" \
        -m conntrack --ctstate ESTABLISHED,RELATED \
        -j ACCEPT 2>/dev/null; do
        ip6tables -D FORWARD \
            -d "${CLIENT_IPV6}/128" \
            -i "$TUN_IF" \
            -o "$LAN_IF" \
            -m conntrack --ctstate ESTABLISHED,RELATED \
            -j ACCEPT
    done

    while ip6tables -C FORWARD \
        -s "${CLIENT_IPV6}/128" \
        -i "$LAN_IF" \
        -o "$WAN_IF" \
        -j REJECT 2>/dev/null; do
        ip6tables -D FORWARD \
            -s "${CLIENT_IPV6}/128" \
            -i "$LAN_IF" \
            -o "$WAN_IF" \
            -j REJECT
    done

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

    ip addr del "${DNS_SOURCE_IP}/32" dev lo 2>/dev/null || true

    ip route flush table "$ROUTE_TABLE" 2>/dev/null || true
    ip -6 route flush table "$ROUTE_TABLE" 2>/dev/null || true
    ip route flush cache 2>/dev/null || true
    ip -6 route flush cache 2>/dev/null || true
    ip link delete "$TUN_IF" 2>/dev/null || true

    if [ "$TABLE_ADDED" -eq 1 ]; then
        sed -i -E \
            "/^[[:space:]]*${TABLE_ID}[[:space:]]+${ROUTE_TABLE}[[:space:]]*$/d" \
            "$RT_TABLES"
    fi

    if [ "$CREATED_DNS_CONFIG" -eq 1 ]; then
        rm -f "$DNS_CONFIG"
    fi

    if [ "$CREATED_INSTANCE" -eq 1 ]; then
        rm -rf "$INSTANCE_DIR"
    fi

    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed "$SERVICE" 2>/dev/null || true
    systemctl reset-failed "$DNS_SERVICE" 2>/dev/null || true

    exit "$exit_code"
}

trap rollback ERR

if [ -e "$HEV_CONFIG" ] ||
   [ -e "$INSTANCE_CONFIG" ] ||
   [ -e "$DNS_CONFIG" ]; then

    echo "ERROR: Instance ${INSTANCE} already exists." >&2
    exit 1
fi

command -v nc >/dev/null 2>&1 || {
    echo "ERROR: nc is not installed. Install netcat-openbsd first." >&2
    exit 1
}

command -v unbound >/dev/null 2>&1 || {
    echo "ERROR: unbound is not installed." >&2
    exit 1
}

command -v unbound-checkconf >/dev/null 2>&1 || {
    echo "ERROR: unbound-checkconf is not installed." >&2
    exit 1
}

echo "Checking proxy ${PROXY_IP}:${PROXY_PORT}..."

NC_FAMILY=""
[ "$IP_MODE" = "ipv4" ] && NC_FAMILY="-4"
[ "$IP_MODE" = "ipv6" ] && NC_FAMILY="-6"

if ! nc $NC_FAMILY -z -w 5 "$PROXY_IP" "$PROXY_PORT"; then
    echo "ERROR: Cannot connect to ${PROXY_IP}:${PROXY_PORT}." >&2
    exit 1
fi

mkdir -p "$INSTANCE_DIR"
CREATED_INSTANCE=1
chmod 750 "$INSTANCE_DIR"

mkdir -p "$DNS_CONFIG_DIR"
chmod 755 "$DNS_CONFIG_DIR"

cat > "$HEV_CONFIG" <<EOF_CONFIG
tunnel:
  name: ${TUN_IF}
  mtu: 1500
  ipv4: ${TUN_IPV4}
  ipv6: ${TUN_IPV6}

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
IP_MODE=${IP_MODE}
CLIENT_IP=${CLIENT_IP}
CLIENT_IPV6=${CLIENT_IPV6}
TUN_IF=${TUN_IF}
TUN_IPV4=${TUN_IPV4}
TUN_IPV6=${TUN_IPV6}
ROUTE_TABLE=${ROUTE_TABLE}
TABLE_ID=${TABLE_ID}
RULE_PRIORITY=${RULE_PRIORITY}
PROXY_IP=${PROXY_IP}

DNS_SOURCE_IP=${DNS_SOURCE_IP}
DNS_SOURCE_IPV6=${DNS_SOURCE_IPV6}
DNS_PORT=${DNS_PORT}
DNS_RULE_PRIORITY=${DNS_RULE_PRIORITY}
DNS_BLOCK_PRIORITY=${DNS_BLOCK_PRIORITY}

LAN_IF=${LAN_IF}
LAN_IP=${LAN_IP}
LAN_NET=${LAN_NET}
LAN_IPV6=${LAN_IPV6}
LAN_NET6=${LAN_NET6}
WAN_IF=${WAN_IF}
WAN_GW=${WAN_GW}
EOF_INSTANCE

if [ "$IP_MODE" = "ipv6" ]; then
cat > "$DNS_CONFIG" <<EOF_DNS
server:
    verbosity: 1

    interface: ${LAN_IPV6}@${DNS_PORT}

    access-control: ${CLIENT_IPV6}/128 allow
    access-control: ${LAN_IPV6}/128 allow
    access-control: ::/0 refuse

    do-ip4: no
    do-ip6: yes
    do-udp: yes
    do-tcp: yes

    tcp-upstream: yes
    outgoing-interface: ${DNS_SOURCE_IPV6}

    hide-identity: yes
    hide-version: yes
forward-zone:
    name: "."
    forward-addr: 2606:4700:4700::1111
    forward-addr: 2001:4860:4860::8888
    forward-first: no

remote-control:
    control-enable: no
EOF_DNS
else
cat > "$DNS_CONFIG" <<EOF_DNS
server:
    verbosity: 1

    interface: ${LAN_IP}@${DNS_PORT}

    access-control: ${CLIENT_IP}/32 allow
    access-control: ${LAN_IP}/32 allow
    access-control: 0.0.0.0/0 refuse

    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes

    tcp-upstream: yes
    outgoing-interface: ${DNS_SOURCE_IP}

    hide-identity: yes
    hide-version: yes
forward-zone:
    name: "."
    forward-addr: 8.8.8.8
    forward-addr: 1.1.1.1
    forward-first: no

remote-control:
    control-enable: no
EOF_DNS
fi

CREATED_DNS_CONFIG=1

chmod 600 "$HEV_CONFIG" "$INSTANCE_CONFIG" "$DNS_CONFIG"

unbound-checkconf "$DNS_CONFIG"

if ! grep -Eq \
    "^[[:space:]]*${TABLE_ID}[[:space:]]+${ROUTE_TABLE}[[:space:]]*$" \
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

systemctl enable --now "$DNS_SERVICE"

sleep 1

if ! systemctl is-active --quiet "$DNS_SERVICE"; then
    echo "ERROR: ${DNS_SERVICE} failed to start." >&2
    systemctl status "$DNS_SERVICE" --no-pager -l || true
    false
fi

trap - ERR

echo
echo "Instance ${INSTANCE} created successfully."
echo "Client IP:       ${CLIENT_IP}"
echo "Tunnel:          ${TUN_IF}"
echo "Tunnel IP:       ${TUN_IPV4}"
echo "Routing table:   ${ROUTE_TABLE} (${TABLE_ID})"
echo "HEV service:     ${SERVICE}"
echo "Proxy:           ${PROXY_IP}:${PROXY_PORT}"
echo
echo "DNS source IP:   ${DNS_SOURCE_IP}"
echo "DNS port:        ${DNS_PORT}"
echo "DNS rule:        ${DNS_RULE_PRIORITY}"
echo "DNS fail-close:  ${DNS_BLOCK_PRIORITY}"
echo "DNS service:     ${DNS_SERVICE}"
