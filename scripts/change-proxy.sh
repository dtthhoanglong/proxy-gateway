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
