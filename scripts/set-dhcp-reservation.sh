#!/bin/bash
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "Cách dùng: sudo $0 INSTANCE MAC_ADDRESS [ipv4|ipv6]"
    exit 1
fi

INSTANCE="$1"
MAC_RAW="$2"
IP_MODE="${3:-ipv4}"
DHCP_CONFIG="/etc/dhcp/dhcpd.conf"
CLIENT_IP="10.0.1.${INSTANCE}"
HOST_NAME="vm${INSTANCE}"
INSTANCE_CONF="/etc/hev/${INSTANCE}/instance.conf"

if ! [[ "$INSTANCE" =~ ^[0-9]+$ ]] || [ "$INSTANCE" -lt 101 ] || [ "$INSTANCE" -gt 120 ]; then
    echo "ERROR: INSTANCE phải nằm trong khoảng 101 đến 120." >&2
    exit 1
fi
case "$IP_MODE" in ipv4|ipv6) ;; *) echo "ERROR: IP_MODE phải là ipv4 hoặc ipv6." >&2; exit 1 ;; esac

MAC="$(printf '%s' "$MAC_RAW" | tr '[:upper:]' '[:lower:]' | tr '-' ':')"
if ! [[ "$MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
    echo "ERROR: Địa chỉ MAC không hợp lệ: $MAC_RAW" >&2
    exit 1
fi
[ -f "$INSTANCE_CONF" ] || { echo "ERROR: Không tìm thấy $INSTANCE_CONF" >&2; exit 1; }

while IFS= read -r f; do
    [ "$f" = "$INSTANCE_CONF" ] && continue
    if grep -qi "^CLIENT_MAC=${MAC}$" "$f" 2>/dev/null; then
        echo "ERROR: MAC $MAC đang được gán cho instance khác." >&2
        exit 1
    fi
done < <(find /etc/hev -mindepth 2 -maxdepth 2 -type f -name instance.conf 2>/dev/null)

python3 - "$INSTANCE_CONF" "$MAC" "$IP_MODE" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1]); mac = sys.argv[2]; mode = sys.argv[3]
lines = p.read_text().splitlines()
def put(key, value):
    prefix = key + "="
    for i, line in enumerate(lines):
        if line.startswith(prefix):
            lines[i] = prefix + value
            return
    lines.insert(0, prefix + value)
put("CLIENT_MAC", mac)
put("IP_MODE", mode)
p.write_text("\n".join(lines) + "\n")
PY

if [ "$IP_MODE" = "ipv6" ]; then
    echo "Gán client IPv6 thành công: VM${INSTANCE} ${MAC} fd10:0:1::${INSTANCE}"
    exit 0
fi

[ -f "$DHCP_CONFIG" ] || { echo "ERROR: Không tìm thấy $DHCP_CONFIG" >&2; exit 1; }
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${DHCP_CONFIG}.bak-${TIMESTAMP}"
TEMP_FILE="$(mktemp)"
CONFIG_INSTALLED=0
cp -a "$DHCP_CONFIG" "$BACKUP"
restore_old_config() {
    rm -f "$TEMP_FILE"
    if [ "$CONFIG_INSTALLED" -eq 1 ]; then
        cp -a "$BACKUP" "$DHCP_CONFIG"
        systemctl restart isc-dhcp-server 2>/dev/null || true
    fi
}
trap restore_old_config ERR

python3 - "$DHCP_CONFIG" "$TEMP_FILE" "$HOST_NAME" "$MAC" "$CLIENT_IP" <<'PY'
import re, sys
from pathlib import Path
source=Path(sys.argv[1]); target=Path(sys.argv[2]); host=sys.argv[3]; mac=sys.argv[4]; ip=sys.argv[5]
text=source.read_text()
text=re.sub(rf"(?ms)^[ \t]*host[ \t]+{re.escape(host)}[ \t]*\{{.*?^[ \t]*\}}[ \t]*\n?", "", text)
if re.search(rf"(?i)hardware[ \t]+ethernet[ \t]+{re.escape(mac)}[ \t]*;", text):
    raise SystemExit(f"MAC {mac} đang được dùng bởi reservation khác")
if re.search(rf"(?i)fixed-address[ \t]+{re.escape(ip)}[ \t]*;", text):
    raise SystemExit(f"IP {ip} đang được dùng bởi reservation khác")
block=f"\nhost {host} {{\n    hardware ethernet {mac};\n    fixed-address {ip};\n}}\n"
target.write_text(text.rstrip()+"\n"+block)
PY

install -o root -g root -m 644 "$TEMP_FILE" "$DHCP_CONFIG"
CONFIG_INSTALLED=1
rm -f "$TEMP_FILE"
dhcpd -t -4 -cf "$DHCP_CONFIG"
systemctl restart isc-dhcp-server
sleep 1
systemctl is-active --quiet isc-dhcp-server
trap - ERR
echo "Gán DHCP reservation IPv4 thành công: VM${INSTANCE} ${MAC} ${CLIENT_IP}"
