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

cp -a "$DHCP_CONFIG" "$BACKUP"

restore_old_config() {
    echo "Đang khôi phục cấu hình DHCP cũ..." >&2
    cp -a "$BACKUP" "$DHCP_CONFIG"
    systemctl restart isc-dhcp-server 2>/dev/null || true
    rm -f "$TEMP_FILE"
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
rm -f "$TEMP_FILE"

dhcpd -t -4 -cf "$DHCP_CONFIG"

systemctl restart isc-dhcp-server
sleep 1

if ! systemctl is-active --quiet isc-dhcp-server; then
    echo "ERROR: isc-dhcp-server không chạy sau khi cập nhật." >&2
    false
fi

trap - ERR

/usr/local/sbin/cleanup-hev-backups.sh	

echo
echo "Gán DHCP reservation thành công."
echo "VM:  ${INSTANCE}"
echo "MAC: ${MAC}"
echo "IP:  ${CLIENT_IP}"
echo "Backup: ${BACKUP}"
