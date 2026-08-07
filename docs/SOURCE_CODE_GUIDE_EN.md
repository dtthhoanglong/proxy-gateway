# Proxy Gateway v1.0.2 -- Source Code Guide

## Objective

This document analyzes the actual Bash source code used by Proxy Gateway
v1.0.2.

Unlike `DEPLOYMENT_GUIDE.md`, this guide focuses on implementation
details:

-   input arguments;
-   generated variables and files;
-   execution order;
-   runtime networking state;
-   rollback behavior;
-   policy routing;
-   iptables fail-close behavior;
-   implementation limitations and possible improvements.

## Scripts covered

  Script                      Role
  --------------------------- --------------------------------------------
  `add-hev-instance.sh`       Provision a new HEV instance
  `hev-instance-up.sh`        Build runtime routing and fail-close state
  `change-proxy.sh`           Change the assigned SOCKS5 proxy
  `set-dhcp-reservation.sh`   Manage DHCP reservations
  `remove-hev-instance.sh`    Decommission an instance
  `cleanup-hev-backups.sh`    Apply backup retention

## High-level flow

``` text
Web UI: Add VM
    ↓
add-hev-instance.sh
    ↓
config.yml + instance.conf
    ↓
systemd starts HEV
    ↓
hev-instance-up.sh
    ↓
route + ip rule + iptables fail-close
    ↓
set-dhcp-reservation.sh
    ↓
VM receives its reserved address
```

------------------------------------------------------------------------

# Chapter 1 -- `add-hev-instance.sh`

## Purpose

Creates a new HEV instance for VM101--VM120. The script generates the
HEV configuration and instance metadata, registers a routing table,
enables the systemd service, and rolls back resources if provisioning
fails.

## Input

``` text
INSTANCE PROXY_IP PROXY_PORT USERNAME PASSWORD
```

Example:

``` bash
sudo add-hev-instance.sh 104 203.0.113.10 3904 User104 'Password'
```

## Execution flow

1.  Enables Bash strict mode with `set -euo pipefail`.
2.  Requires exactly five arguments.
3.  Restricts the instance number to 101--120.
4.  Validates the proxy port as 1--65535.
5.  Derives per-instance values such as client IP, HEV interface, tunnel
    IP, routing table, table ID, and rule priority.
6.  Rejects an instance that already exists.
7.  Verifies that `nc` is available.
8.  Tests TCP reachability to the proxy.
9.  Creates `/etc/hev/<INSTANCE>/`.
10. Generates `config.yml`.
11. Generates `instance.conf`.
12. Registers the routing table in `/etc/iproute2/rt_tables`.
13. Enables and starts `hev-socks5-tunnel@<INSTANCE>.service`.
14. Verifies that the service is active.
15. Uses `rollback()` to remove partially created state if an error
    occurs.

## Rollback

`trap rollback ERR` protects the provisioning transaction. Depending on
what was created, rollback stops/disables the service, removes the
policy rule, flushes the routing table, deletes the tunnel interface,
removes the routing-table entry, deletes the new instance directory,
reloads systemd, and resets failed service state.

The `CREATED_INSTANCE` and `TABLE_ADDED` flags prevent rollback from
deleting unrelated pre-existing resources.

## Generated files

`config.yml` contains HEV tunnel and SOCKS5 settings, including
credentials.

`instance.conf` contains Proxy Gateway routing metadata used later by
`hev-instance-up.sh`.

## Important observations

-   `nc` proves only that the TCP port is reachable; it does not verify
    SOCKS5 authentication.
-   Proxy IP validation is primarily performed by the Web UI rather than
    this script.
-   WAN/LAN values are tied to the tested gateway configuration;
    hardware with different interfaces must use matching configuration.
-   Credential-bearing files are protected with restrictive permissions.

## Complete source code

``` bash
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
```

------------------------------------------------------------------------

# Chapter 2 -- `hev-instance-up.sh`

## Purpose

Builds the runtime networking state after HEV creates the tunnel
interface. systemd invokes this script through `ExecStartPost`.

## Input

``` text
INSTANCE
```

## Execution flow

1.  Locates `/etc/hev/<INSTANCE>/instance.conf`.
2.  Stops if the metadata file is missing.
3.  Sources the metadata.
4.  Waits for the HEV interface to appear.
5.  Creates a `/32` WAN route to the SOCKS5 server.
6.  Creates the LAN route in the per-VM routing table.
7.  Creates the default route through the HEV interface.
8.  Removes any stale policy rule with the same priority.
9.  Adds the source-based policy rule for the VM.
10. Flushes the route cache.
11. Installs forwarding rules.
12. Installs a direct-WAN `REJECT` rule for fail-close behavior.

## Why the proxy `/32` route is required

The VM is policy-routed into HEV, while the HEV process itself must
still reach the SOCKS5 server over the real WAN. The explicit proxy
route prevents recursive routing back into the tunnel.

## Policy routing

Only traffic sourced from the VM's assigned address is sent to that VM's
routing table. This is the basis for assigning one proxy per VM.

## Fail-close

The direct LAN-to-WAN `REJECT` rule prevents a managed VM from falling
back to the gateway's WAN connection if HEV or the SOCKS5 proxy becomes
unavailable.

## Idempotency

`ip route replace`, removal of stale policy rules, and
`iptables -C ... || iptables -A ...` make repeated starts safer and
avoid duplicate firewall entries.

## Important observations

-   `instance.conf` is sourced as root and therefore must remain
    root-controlled.
-   Runtime firewall/routing state is recreated when the service starts.
-   The fail-close rule intentionally remains useful when the tunnel is
    unavailable.

## Complete source code

``` bash
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
```

------------------------------------------------------------------------

# Chapter 3 -- `change-proxy.sh`

## Purpose

Changes the SOCKS5 proxy assigned to an existing instance without
recreating the VM or DHCP reservation.

## Input

``` text
INSTANCE PROXY_IP PROXY_PORT USERNAME PASSWORD
```

## Execution flow

1.  Validates argument count, instance range, and port.
2.  Confirms that `config.yml` and `instance.conf` exist.
3.  Tests TCP connectivity to the new proxy.
4.  Creates timestamped backups of both files.
5.  Installs an error trap that restores the previous configuration.
6.  Uses embedded Python to modify the `socks5:` section.
7.  Verifies that all expected fields were updated.
8.  Updates `PROXY_IP` in `instance.conf`.
9.  Restores restrictive permissions.
10. Restarts the HEV service.
11. Verifies that the service becomes active.
12. Removes the error trap and optionally cleans old backups.

## Why embedded Python is used

The Python code follows indentation and changes only the expected keys
inside the `socks5:` section. It also tracks the updated fields so a
malformed or unexpected configuration causes a failure instead of a
silent partial edit.

## Rollback

If editing or service restart fails, the previous `config.yml` and
`instance.conf` are restored and the service is restarted using the old
configuration.

## Important observations

-   Only `PROXY_IP` must be copied into `instance.conf`; port and
    credentials belong to HEV's `config.yml`.
-   TCP reachability does not prove that the supplied username/password
    are accepted.
-   Backups may contain credentials and must be protected.

## Complete source code

``` bash
#!/bin/bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "Cách dùng:"
    echo "  sudo $0 INSTANCE PROXY_IP PROXY_PORT USERNAME PASSWORD"
    echo
    echo "Ví dụ:"
    echo "  sudo $0 102 203.0.113.10 3902 ExampleUser2 'ChangeThisPassword'"
    exit 1
fi

INSTANCE="$1"
NEW_PROXY_IP="$2"
NEW_PROXY_PORT="$3"
NEW_PROXY_USER="$4"
NEW_PROXY_PASS="$5"

INSTANCE_DIR="/etc/hev/${INSTANCE}"
HEV_CONFIG="${INSTANCE_DIR}/config.yml"
INSTANCE_CONFIG="${INSTANCE_DIR}/instance.conf"
SERVICE="hev-socks5-tunnel@${INSTANCE}.service"

if ! [[ "$INSTANCE" =~ ^[0-9]+$ ]] ||
   [ "$INSTANCE" -lt 101 ] ||
   [ "$INSTANCE" -gt 120 ]; then
    echo "ERROR: INSTANCE phải nằm trong khoảng 101 đến 120." >&2
    exit 1
fi

if ! [[ "$NEW_PROXY_PORT" =~ ^[0-9]+$ ]] ||
   [ "$NEW_PROXY_PORT" -lt 1 ] ||
   [ "$NEW_PROXY_PORT" -gt 65535 ]; then
    echo "ERROR: Port proxy không hợp lệ." >&2
    exit 1
fi

if [ ! -f "$HEV_CONFIG" ]; then
    echo "ERROR: Không tìm thấy $HEV_CONFIG" >&2
    exit 1
fi

if [ ! -f "$INSTANCE_CONFIG" ]; then
    echo "ERROR: Không tìm thấy $INSTANCE_CONFIG" >&2
    exit 1
fi

echo "Đang kiểm tra ${NEW_PROXY_IP}:${NEW_PROXY_PORT}..."

if ! nc -z -w 5 "$NEW_PROXY_IP" "$NEW_PROXY_PORT"; then
    echo "ERROR: Không thể kết nối tới ${NEW_PROXY_IP}:${NEW_PROXY_PORT}." >&2
    exit 1
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
HEV_BACKUP="${HEV_CONFIG}.bak-${TIMESTAMP}"
INSTANCE_BACKUP="${INSTANCE_CONFIG}.bak-${TIMESTAMP}"

cp -a "$HEV_CONFIG" "$HEV_BACKUP"
cp -a "$INSTANCE_CONFIG" "$INSTANCE_BACKUP"

restore_old_config() {
    echo "Đang khôi phục cấu hình cũ..." >&2
    cp -a "$HEV_BACKUP" "$HEV_CONFIG"
    cp -a "$INSTANCE_BACKUP" "$INSTANCE_CONFIG"
    systemctl restart "$SERVICE" 2>/dev/null || true
}

trap restore_old_config ERR

python3 - "$HEV_CONFIG" \
    "$NEW_PROXY_IP" \
    "$NEW_PROXY_PORT" \
    "$NEW_PROXY_USER" \
    "$NEW_PROXY_PASS" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
proxy_ip = sys.argv[2]
proxy_port = sys.argv[3]
proxy_user = sys.argv[4]
proxy_pass = sys.argv[5]

lines = path.read_text().splitlines()
result = []
inside_socks5 = False
updated = {
    "address": False,
    "port": False,
    "username": False,
    "password": False,
}

for line in lines:
    stripped = line.strip()

    if stripped == "socks5:":
        inside_socks5 = True
        result.append(line)
        continue

    if inside_socks5 and line and not line.startswith((" ", "\t")):
        inside_socks5 = False

    if inside_socks5:
        indent = line[:len(line) - len(line.lstrip())]

        if stripped.startswith("address:"):
            line = f"{indent}address: {proxy_ip}"
            updated["address"] = True
        elif stripped.startswith("port:"):
            line = f"{indent}port: {proxy_port}"
            updated["port"] = True
        elif stripped.startswith("username:"):
            line = f"{indent}username: {proxy_user}"
            updated["username"] = True
        elif stripped.startswith("password:"):
            line = f"{indent}password: {proxy_pass}"
            updated["password"] = True

    result.append(line)

missing = [name for name, found in updated.items() if not found]
if missing:
    raise SystemExit(
        "Thiếu trường trong phần socks5: " + ", ".join(missing)
    )

path.write_text("\n".join(result) + "\n")
PY

if grep -q '^PROXY_IP=' "$INSTANCE_CONFIG"; then
    sed -i "s|^PROXY_IP=.*|PROXY_IP=${NEW_PROXY_IP}|" "$INSTANCE_CONFIG"
else
    echo "PROXY_IP=${NEW_PROXY_IP}" >> "$INSTANCE_CONFIG"
fi

chmod 600 "$HEV_CONFIG" "$INSTANCE_CONFIG"

systemctl restart "$SERVICE"
sleep 2

if ! systemctl is-active --quiet "$SERVICE"; then
    echo "ERROR: $SERVICE không hoạt động sau khi thay proxy." >&2
    false
fi

trap - ERR

if [ -x /usr/local/sbin/cleanup-hev-backups.sh ]; then
    /usr/local/sbin/cleanup-hev-backups.sh || true
fi

echo
echo "Đổi proxy thành công."
echo "VM:       ${INSTANCE}"
echo "Proxy:    ${NEW_PROXY_IP}:${NEW_PROXY_PORT}"
echo "Username: ${NEW_PROXY_USER}"
echo "Service:  ${SERVICE}"
```

------------------------------------------------------------------------

# Chapter 4 -- `set-dhcp-reservation.sh`

## Purpose

Creates or updates the `vm<INSTANCE>` reservation in
`/etc/dhcp/dhcpd.conf`.

## Input

``` text
INSTANCE MAC_ADDRESS
```

## MAC normalization

The script converts uppercase to lowercase and `-` to `:`, then
validates the normalized address as six hexadecimal octets.

## Execution flow

1.  Validates the instance number.
2.  Normalizes and validates the MAC address.
3.  Confirms that `dhcpd.conf` exists.
4.  Creates a timestamped backup.
5.  Creates a temporary file.
6.  Installs an error trap.
7.  Uses Python to remove the previous host block for the same VM.
8.  Rejects a MAC already assigned to another host.
9.  Rejects a fixed IP already assigned to another host.
10. Appends the new host reservation.
11. Installs the temporary file as the live configuration.
12. Runs `dhcpd -t`.
13. Restarts ISC DHCP Server.
14. Verifies that the service is active.
15. Clears the trap and optionally cleans old backups.

## Rollback

The live configuration is restored only if the new file had already been
installed. If validation fails before that point, the original live
configuration was never changed.

## Important observations

-   Duplicate MAC and fixed-IP assignments are explicitly prevented.
-   Global-scope ISC DHCP host declarations are used.
-   Backup cleanup is secondary; a cleanup failure does not invalidate a
    successful DHCP update.

## Complete source code

``` bash
#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Cách dùng:"
    echo "  sudo $0 INSTANCE MAC_ADDRESS"
    echo
    echo "Ví dụ:"
    echo "  sudo $0 103 00:0C:29:66:CD:07"
    exit 1
fi

INSTANCE="$1"
MAC_RAW="$2"

DHCP_CONFIG="/etc/dhcp/dhcpd.conf"
CLIENT_IP="10.0.1.${INSTANCE}"
HOST_NAME="vm${INSTANCE}"

if ! [[ "$INSTANCE" =~ ^[0-9]+$ ]] ||
   [ "$INSTANCE" -lt 101 ] ||
   [ "$INSTANCE" -gt 120 ]; then
    echo "ERROR: INSTANCE phải nằm trong khoảng 101 đến 120." >&2
    exit 1
fi

MAC="$(printf '%s' "$MAC_RAW" | tr '[:upper:]' '[:lower:]' | tr '-' ':')"

if ! [[ "$MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
    echo "ERROR: Địa chỉ MAC không hợp lệ: $MAC_RAW" >&2
    exit 1
fi

if [ ! -f "$DHCP_CONFIG" ]; then
    echo "ERROR: Không tìm thấy $DHCP_CONFIG" >&2
    exit 1
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${DHCP_CONFIG}.bak-${TIMESTAMP}"
TEMP_FILE="$(mktemp)"
CONFIG_INSTALLED=0

cp -a "$DHCP_CONFIG" "$BACKUP"

restore_old_config() {
    rm -f "$TEMP_FILE"

    if [ "$CONFIG_INSTALLED" -eq 1 ]; then
        echo "Đang khôi phục cấu hình DHCP cũ..." >&2
        cp -a "$BACKUP" "$DHCP_CONFIG"
        systemctl restart isc-dhcp-server 2>/dev/null || true
    fi
}

trap restore_old_config ERR

python3 - "$DHCP_CONFIG" "$TEMP_FILE" "$HOST_NAME" "$MAC" "$CLIENT_IP" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
host_name = sys.argv[3]
mac = sys.argv[4]
ip = sys.argv[5]

text = source.read_text()

# Xóa reservation cũ có cùng tên host.
host_pattern = re.compile(
    rf"(?ms)^[ \t]*host[ \t]+{re.escape(host_name)}[ \t]*\{{.*?^[ \t]*\}}[ \t]*\n?"
)
text = host_pattern.sub("", text)

# Không cho một MAC đang được gán cho host khác.
mac_pattern = re.compile(
    rf"(?i)hardware[ \t]+ethernet[ \t]+{re.escape(mac)}[ \t]*;"
)
if mac_pattern.search(text):
    raise SystemExit(f"MAC {mac} đang được dùng bởi reservation khác")

# Không cho IP này đang được fixed-address cho host khác.
ip_pattern = re.compile(
    rf"(?i)fixed-address[ \t]+{re.escape(ip)}[ \t]*;"
)
if ip_pattern.search(text):
    raise SystemExit(f"IP {ip} đang được dùng bởi reservation khác")

block = (
    f"\nhost {host_name} {{\n"
    f"    hardware ethernet {mac};\n"
    f"    fixed-address {ip};\n"
    f"}}\n"
)

target.write_text(text.rstrip() + "\n" + block)
PY

install -o root -g root -m 644 "$TEMP_FILE" "$DHCP_CONFIG"
CONFIG_INSTALLED=1
rm -f "$TEMP_FILE"

dhcpd -t -4 -cf "$DHCP_CONFIG"

systemctl restart isc-dhcp-server
sleep 1

if ! systemctl is-active --quiet isc-dhcp-server; then
    echo "ERROR: isc-dhcp-server không chạy sau khi cập nhật." >&2
    false
fi

trap - ERR

if [ -x /usr/local/sbin/cleanup-hev-backups.sh ]; then
    /usr/local/sbin/cleanup-hev-backups.sh || true
fi

echo
echo "Gán DHCP reservation thành công."
echo "VM:  ${INSTANCE}"
echo "MAC: ${MAC}"
echo "IP:  ${CLIENT_IP}"
echo "Backup: ${BACKUP}"
```

------------------------------------------------------------------------

# Chapter 5 -- `remove-hev-instance.sh`

## Purpose

Removes the Proxy Gateway configuration for one managed instance: HEV
configuration, DHCP reservation, policy routing, firewall state, tunnel
interface, and routing-table registration.

It does not delete the actual VMware, Proxmox, ESXi, or VirtualBox
guest.

## Input

``` text
INSTANCE
```

## Execution flow

1.  Validates the instance number.
2.  Confirms that `/etc/hev/<INSTANCE>` exists.
3.  Loads real instance metadata when available.
4.  Backs up the complete instance under `/root/`.
5.  Backs up DHCP configuration.
6.  Removes the VM host block from DHCP.
7.  Installs and validates the new DHCP configuration.
8.  Restarts and verifies DHCP.
9.  Stops and disables the HEV service.
10. Removes the policy rule and flushes the routing table.
11. Removes matching iptables rules.
12. Deletes the tunnel interface if still present.
13. Removes the routing-table registration.
14. Deletes the instance directory.
15. Reloads/reset systemd state.
16. Cleans old backups.

## DHCP rollback

The error trap protects DHCP changes so a failed DHCP edit does not
proceed into destructive HEV cleanup.

## Firewall cleanup

Rules are removed in loops, allowing the script to clean duplicate rules
that may have accumulated from earlier manual operations.

## Important observations

-   Removed-instance backups can contain proxy credentials.
-   The script loads `instance.conf` so it can clean installations whose
    interface values differ from defaults.
-   A future version could improve transaction tracking for rare
    failures that occur after DHCP succeeds but during later network
    cleanup.

## Complete source code

``` bash
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

DHCP_CONFIG="/etc/dhcp/dhcpd.conf"
DHCP_HOST="vm${INSTANCE}"
DHCP_BACKUP=""
DHCP_CHANGED=0
TEMP_DHCP=""

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

    install -o root -g root -m 644 "$TEMP_DHCP" "$DHCP_CONFIG"
    DHCP_CHANGED=1
    rm -f "$TEMP_DHCP"
    TEMP_DHCP=""

    dhcpd -t -4 -cf "$DHCP_CONFIG"
    systemctl restart isc-dhcp-server
    sleep 1

    if ! systemctl is-active --quiet isc-dhcp-server; then
        echo "ERROR: isc-dhcp-server is not active after removing reservation." >&2
        false
    fi
fi

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

trap - ERR

if [ -x /usr/local/sbin/cleanup-hev-backups.sh ]; then
    /usr/local/sbin/cleanup-hev-backups.sh || true
fi

echo
echo "Removed HEV instance ${INSTANCE}."
echo "Removed DHCP reservation: ${DHCP_HOST}"
echo "Backup: ${BACKUP_DIR}"
echo "Service: ${SERVICE}"
echo "Tunnel: ${TUN_IF}"
echo "Routing table: ${ROUTE_TABLE} (${TABLE_ID})"
```

------------------------------------------------------------------------

# Chapter 6 -- `cleanup-hev-backups.sh`

## Purpose

Applies retention limits to automatic backups so routine management does
not consume storage indefinitely.

## Retention policy

The current policy retains:

-   10 DHCP configuration backups;
-   10 `config.yml` backups per HEV instance;
-   10 `instance.conf` backups per HEV instance;
-   5 removed-instance backup directories.

## `cleanup_files`

The function gathers matching files with modification timestamps, sorts
newest first, and deletes entries beyond the configured retention count.

## `cleanup_directories`

The directory cleanup uses the same newest-first retention model for
`/root/hev-removed-*`.

## Strengths

-   Paths are stored in arrays and quoted during deletion.
-   `rm --` protects against option-like filenames.
-   Empty result sets are handled safely.
-   Retention is applied per HEV instance rather than as one global
    quota.

## Important observations

-   Retention is based on modification time rather than parsing
    timestamps from filenames.
-   Full manual backups under `/root/proxy-gateway-backups` are
    intentionally outside this script's scope.
-   Root privileges are required for the protected paths involved.

## Complete source code

``` bash
#!/bin/bash
set -euo pipefail

KEEP_CONFIG_BACKUPS=10
KEEP_REMOVED_INSTANCES=5

cleanup_files() {
    local pattern="$1"
    local keep="$2"

    mapfile -t files < <(
        find "$(dirname "$pattern")" \
            -maxdepth 1 \
            -type f \
            -name "$(basename "$pattern")" \
            -printf '%T@ %p\n' 2>/dev/null |
        sort -nr |
        cut -d' ' -f2-
    )

    if [ "${#files[@]}" -le "$keep" ]; then
        return 0
    fi

    for ((i=keep; i<${#files[@]}; i++)); do
        rm -f -- "${files[$i]}"
    done
}

cleanup_directories() {
    local parent="$1"
    local name_pattern="$2"
    local keep="$3"

    mapfile -t dirs < <(
        find "$parent" \
            -maxdepth 1 \
            -mindepth 1 \
            -type d \
            -name "$name_pattern" \
            -printf '%T@ %p\n' 2>/dev/null |
        sort -nr |
        cut -d' ' -f2-
    )

    if [ "${#dirs[@]}" -le "$keep" ]; then
        return 0
    fi

    for ((i=keep; i<${#dirs[@]}; i++)); do
        rm -rf -- "${dirs[$i]}"
    done
}

# DHCP backups.
cleanup_files \
    "/etc/dhcp/dhcpd.conf.bak-*" \
    "$KEEP_CONFIG_BACKUPS"

# HEV config backups của từng instance.
for instance_dir in /etc/hev/[0-9]*; do
    [ -d "$instance_dir" ] || continue

    cleanup_files \
        "${instance_dir}/config.yml.bak-*" \
        "$KEEP_CONFIG_BACKUPS"

    cleanup_files \
        "${instance_dir}/instance.conf.bak-*" \
        "$KEEP_CONFIG_BACKUPS"
done

# Backup instance đã bị xóa.
cleanup_directories \
    "/root" \
    "hev-removed-*" \
    "$KEEP_REMOVED_INSTANCES"

exit 0
```

------------------------------------------------------------------------

# Chapter 7 -- How the Scripts Work Together

## Add VM

``` text
app.py
  ├─ add-hev-instance.sh
  │    ├─ creates config.yml
  │    ├─ creates instance.conf
  │    ├─ registers rt_tables entry
  │    └─ starts systemd HEV instance
  │          └─ ExecStartPost: hev-instance-up.sh
  │                ├─ proxy WAN route
  │                ├─ per-VM routing table
  │                ├─ source policy rule
  │                ├─ forwarding rules
  │                └─ fail-close REJECT
  └─ set-dhcp-reservation.sh
       ├─ backs up dhcpd.conf
       ├─ creates/updates reservation
       ├─ validates with dhcpd -t
       └─ restarts DHCP
```

## Change Proxy

``` text
app.py
  └─ change-proxy.sh
       ├─ tests TCP reachability
       ├─ backs up configuration
       ├─ updates SOCKS5 fields
       ├─ updates routing metadata
       ├─ restarts HEV
       └─ restores old configuration on failure
```

## Delete VM

``` text
app.py
  └─ remove-hev-instance.sh
       ├─ backs up the instance
       ├─ removes DHCP reservation
       ├─ stops/disables HEV
       ├─ removes rules/routes/firewall state
       ├─ removes rt_tables entry
       └─ removes /etc/hev/<instance>
```

# Chapter 8 -- Possible Improvements for a Future Release

1.  Move hard-coded WAN/LAN values into a single gateway configuration
    source.
2.  Validate proxy IP addresses directly in the Bash management layer.
3.  Test actual SOCKS5 authentication instead of TCP connectivity only.
4.  Consider a dedicated YAML parser for proxy configuration updates.
5.  Add file locking around concurrent `dhcpd.conf` modifications.
6.  Add finer-grained transaction state to Delete VM.
7.  Add automated tests for DHCP host-block parsing.
8.  Add a standard diagnostic command that redacts credentials.
9.  Consider an nftables abstraction in a future major version.
10. Standardize user-facing messages across scripts and Web UI.

# End of Document
