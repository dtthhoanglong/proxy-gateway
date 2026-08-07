# Proxy Gateway v1.0.3 – Source Code Guide

## Mục tiêu

Tài liệu này phân tích mã nguồn thật của sáu Bash script trong Proxy Gateway v1.0.3.

Khác với `DEPLOYMENT_GUIDE.md`, tài liệu này tập trung vào:

- từng tham số đầu vào;
- biến được sinh;
- thứ tự thực thi;
- file và runtime state bị thay đổi;
- rollback;
- policy routing;
- iptables fail-close;
- giới hạn và điểm có thể cải tiến.

## Danh sách script

| Script | Vai trò |
|---|---|
| `add-hev-instance.sh` | Provision instance |
| `hev-instance-up.sh` | Runtime routing và fail-close |
| `change-proxy.sh` | Update SOCKS5 proxy |
| `set-dhcp-reservation.sh` | Quản lý DHCP reservation |
| `remove-hev-instance.sh` | Decommission instance |
| `cleanup-hev-backups.sh` | Backup retention |
| `dns-instance-up.sh` | Dựng runtime DNS riêng theo VM |

## Luồng tổng thể

```text
Web UI Add VM
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
VM nhận IP cố định

Web UI Change Proxy
    ↓
change-proxy.sh
    ↓
backup + update + restart + rollback on error

Web UI Delete VM
    ↓
remove-hev-instance.sh
    ↓
DHCP cleanup + service stop + route/rule/firewall cleanup
```

---

# Chapter 1 – `add-hev-instance.sh`

## Mục đích

Tạo một HEV instance mới cho VM101–VM120. Script sinh hai file cấu hình, đăng ký routing table, bật systemd service và rollback nếu quá trình tạo bị lỗi.

## Đầu vào

```text
INSTANCE PROXY_IP PROXY_PORT USERNAME PASSWORD
```

Ví dụ:

```bash
sudo add-hev-instance.sh 104 203.0.113.10 3904 User104 'Password'
```

## Luồng xử lý

1. Bật Bash strict mode bằng `set -euo pipefail`.
2. Kiểm tra đúng 5 tham số.
3. Giới hạn instance trong khoảng 101–120.
4. Kiểm tra proxy port từ 1–65535.
5. Sinh các giá trị theo instance:
   - `CLIENT_IP=10.0.1.<INSTANCE>`
   - `TUN_IF=hev<INSTANCE>`
   - `TUN_IPV4=198.18.0.<INSTANCE-100>`
   - `ROUTE_TABLE=hev<INSTANCE>`
   - `TABLE_ID=<INSTANCE+100>`
   - `RULE_PRIORITY=<INSTANCE+900>`
6. Kiểm tra instance chưa tồn tại.
7. Kiểm tra lệnh `nc` đã được cài.
8. Kiểm tra TCP tới proxy bằng `nc -z -w 5`.
9. Tạo `/etc/hev/<INSTANCE>/`.
10. Sinh `config.yml` cho HEV.
11. Sinh `instance.conf` cho routing.
12. Thêm table vào `/etc/iproute2/rt_tables`.
13. Enable và start `hev-socks5-tunnel@<INSTANCE>.service`.
14. Xác nhận service đang active.
15. Nếu có lỗi, hàm `rollback()` dọn các tài nguyên đã tạo.

## Cơ chế rollback

`trap rollback ERR` bắt lỗi sau khi trap được thiết lập. Hàm rollback:

- stop/disable service;
- xóa policy rule theo priority;
- flush routing table;
- xóa tunnel interface;
- xóa dòng routing table nếu script vừa thêm;
- xóa thư mục instance nếu script vừa tạo;
- daemon-reload và reset trạng thái failed.

Hai cờ `CREATED_INSTANCE` và `TABLE_ADDED` giúp script chỉ xóa những tài nguyên do lần chạy hiện tại tạo ra.

## File được sinh

### `config.yml`

Chứa tunnel name, tunnel IP, proxy IP/port, username/password và timeout của HEV.

### `instance.conf`

Chứa metadata để `hev-instance-up.sh` dựng route và firewall:

```text
CLIENT_IP
TUN_IF
ROUTE_TABLE
TABLE_ID
RULE_PRIORITY
PROXY_IP
LAN_IF
LAN_NET
WAN_IF
WAN_GW
```

## Điểm cần lưu ý

- `nc` chỉ xác nhận TCP port mở; không xác nhận SOCKS5 authentication hoạt động.
- Script không tự kiểm tra định dạng `PROXY_IP`; Web UI thực hiện kiểm tra IP trước khi gọi script.
- `LAN_IF=enp1s0`, `WAN_IF=wlp2s0`, `WAN_GW=192.168.2.1` đang hardcode theo máy J3160 thực tế. Khi triển khai trên phần cứng khác cần sửa template hoặc cải tiến script đọc từ `gateway.conf`.
- File chứa proxy password được đặt mode `600`, đây là lựa chọn đúng.

## Toàn bộ source code

```bash
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

---

# Chapter 2 – `hev-instance-up.sh`

## Mục đích

Thiết lập runtime networking sau khi tiến trình HEV đã tạo tunnel interface. Script này được systemd gọi bằng `ExecStartPost`.

## Đầu vào

```text
INSTANCE
```

Ví dụ systemd gọi:

```bash
/usr/local/sbin/hev-instance-up.sh 104
```

## Luồng xử lý

1. Xác định `/etc/hev/<INSTANCE>/instance.conf`.
2. Dừng nếu file không tồn tại.
3. `source` file cấu hình để nạp các biến.
4. Chờ tối đa 30 lần × 0,5 giây, tổng khoảng 15 giây, để tunnel xuất hiện.
5. Tạo route `/32` tới proxy qua WAN.
6. Tạo route LAN trong table riêng.
7. Tạo default route của table riêng qua HEV tunnel.
8. Xóa policy rule cùng priority nếu còn từ lần trước.
9. Thêm policy rule theo source IP của VM.
10. Flush route cache.
11. Thêm hai rule FORWARD cho chiều đi và chiều về.
12. Thêm rule REJECT từ VM trực tiếp ra WAN để fail-close.

## Vì sao cần route `/32` tới proxy

Traffic của VM bị policy-route vào HEV. Bản thân HEV vẫn cần kết nối tới SOCKS5 server qua WAN thật. Route:

```bash
ip route replace "${PROXY_IP}/32" via "$WAN_GW" dev "$WAN_IF"
```

bảo đảm kết nối tới proxy không bị vòng lặp đi ngược vào tunnel.

## Policy routing

```bash
ip rule add priority "$RULE_PRIORITY" \
    from "${CLIENT_IP}/32" lookup "$ROUTE_TABLE"
```

Chỉ traffic có source đúng IP của VM mới đi vào table tương ứng.

## Fail-close

Rule:

```bash
iptables -A FORWARD \
    -s "${CLIENT_IP}/32" \
    -i "$LAN_IF" \
    -o "$WAN_IF" \
    -j REJECT
```

ngăn VM đi thẳng ra WAN. Nếu tunnel/proxy lỗi, VM mất Internet thay vì lộ WAN IP.

## Tính idempotent

- `ip route replace` có thể chạy lại an toàn.
- Script xóa rule cùng priority trước khi thêm lại.
- `iptables -C ... || iptables ...` tránh tạo rule trùng.

## Điểm cần lưu ý

- `source "$CONF"` chạy dưới quyền root, do đó `instance.conf` phải chỉ cho root ghi.
- iptables runtime không được lưu riêng; chúng được tái tạo khi service start.
- Khi service chỉ stop mà không remove, fail-close rule vẫn tồn tại, đúng với thiết kế.
- Script phụ thuộc `iptables`, `iproute2` và module conntrack.

## Toàn bộ source code

```bash
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

---

# Chapter 3 – `change-proxy.sh`

## Mục đích

Đổi SOCKS5 proxy cho một instance đang tồn tại mà không tạo lại VM hoặc DHCP reservation.

## Đầu vào

```text
INSTANCE PROXY_IP PROXY_PORT USERNAME PASSWORD
```

## Luồng xử lý

1. Kiểm tra đủ 5 tham số.
2. Kiểm tra instance 101–120.
3. Kiểm tra port hợp lệ.
4. Xác nhận `config.yml` và `instance.conf` tồn tại.
5. Kiểm tra TCP tới proxy mới.
6. Tạo backup timestamp cho hai file.
7. Cài `trap restore_old_config ERR`.
8. Chạy Python nhúng để sửa đúng section `socks5:`.
9. Xác nhận cả 4 field đã được tìm và cập nhật.
10. Cập nhật `PROXY_IP` trong `instance.conf`.
11. Đặt quyền `600`.
12. Restart service.
13. Xác nhận service active.
14. Tắt trap và gọi cleanup backup nếu có.

## Vì sao dùng Python thay cho `sed`

Python duyệt cấu trúc theo indentation và chỉ thay các key nằm bên trong section `socks5:`:

```text
address
port
username
password
```

Biến `updated` xác nhận không có field nào bị thiếu. Nếu cấu trúc YAML không đúng như mong đợi, script dừng thay vì âm thầm tạo cấu hình nửa vời.

## Rollback

Nếu cập nhật hoặc restart service lỗi:

- khôi phục `config.yml`;
- khôi phục `instance.conf`;
- restart service bằng cấu hình cũ.

## Điểm cần lưu ý

- `instance.conf` chỉ cập nhật `PROXY_IP`, vì routing startup cần IP proxy để tạo route `/32`; port và credential chỉ thuộc `config.yml`.
- Kiểm tra `nc` không xác nhận username/password.
- Script hiện không kiểm tra `command -v nc` như `add-hev-instance.sh`; package này phải được cài trong deployment.
- Backup chứa credential nên phải bảo vệ quyền truy cập.

## Toàn bộ source code

```bash
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

---

# Chapter 4 – `set-dhcp-reservation.sh`

## Mục đích

Tạo hoặc cập nhật DHCP reservation `vm<INSTANCE>` trong `/etc/dhcp/dhcpd.conf`.

## Đầu vào

```text
INSTANCE MAC_ADDRESS
```

## Chuẩn hóa MAC

```bash
tr '[:upper:]' '[:lower:]' | tr '-' ':'
```

Cho phép người dùng nhập chữ hoa hoặc dấu gạch ngang, sau đó chuẩn hóa thành dạng:

```text
00:0c:29:aa:bb:cc
```

Regex cuối cùng bắt buộc đúng 6 octet.

## Luồng xử lý

1. Kiểm tra instance 101–120.
2. Chuẩn hóa và validate MAC.
3. Xác nhận `dhcpd.conf` tồn tại.
4. Tạo backup timestamp.
5. Tạo temp file.
6. Đặt `trap restore_old_config ERR`.
7. Python xóa host block cũ cùng tên.
8. Kiểm tra MAC không được dùng bởi host khác.
9. Kiểm tra fixed IP không được dùng bởi host khác.
10. Thêm host block mới ở cuối file.
11. Install temp file thành `dhcpd.conf` với owner/mode đúng.
12. Chạy `dhcpd -t`.
13. Restart DHCP.
14. Kiểm tra service active.
15. Tắt trap và cleanup backup.

## Reservation được sinh

```text
host vm104 {
    hardware ethernet 00:0c:29:4e:24:6f;
    fixed-address 10.0.1.104;
}
```

## Rollback

Biến `CONFIG_INSTALLED` chỉ được đặt thành `1` sau khi temp file đã được cài. Nếu lỗi xảy ra sau thời điểm này, backup được khôi phục và DHCP được restart.

Nếu Python lỗi trước khi file mới được cài, cấu hình live chưa thay đổi nên không cần restore.

## Điểm cần lưu ý

- Regex host block giả định dấu `}` kết thúc block nằm ở đầu dòng hoặc sau whitespace.
- Script append reservation ở cuối file, không đặt nó bên trong subnet block. ISC DHCP cho phép host declaration ở global scope.
- Script bảo vệ khỏi trùng MAC và fixed IP.
- Backup cleanup là optional và lỗi cleanup không làm thất bại thao tác DHCP chính.

## Toàn bộ source code

```bash
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

---

# Chapter 5 – `remove-hev-instance.sh`

## Mục đích

Xóa toàn bộ cấu hình Proxy Gateway của một instance, gồm HEV, DHCP reservation, policy routing, firewall và routing-table registration.

Script không xóa máy ảo thực tế trên VMware/Proxmox.

## Đầu vào

```text
INSTANCE
```

## Luồng xử lý

1. Validate instance 101–120.
2. Xác nhận `/etc/hev/<INSTANCE>` tồn tại.
3. Đặt các giá trị mặc định.
4. Nếu có `instance.conf`, source file để lấy cấu hình thực tế.
5. Backup toàn bộ instance vào `/root/hev-removed-...`.
6. Tạo backup DHCP.
7. Python xóa host block `vm<INSTANCE>`.
8. Install và validate DHCP mới.
9. Restart và kiểm tra DHCP.
10. Stop/disable HEV service.
11. Xóa policy rule.
12. Flush table và route cache.
13. Xóa các rule iptables theo vòng lặp.
14. Xóa tunnel interface nếu còn.
15. Xóa dòng trong `/etc/iproute2/rt_tables`.
16. Xóa thư mục instance.
17. daemon-reload/reset-failed.
18. Cleanup backup cũ.

## Rollback DHCP

`trap restore_dhcp ERR` chỉ rollback phần DHCP. Đây là lựa chọn thận trọng vì script xóa HEV/networking sau khi DHCP đã được xác nhận tốt.

Nếu DHCP update thất bại:

- temp file bị xóa;
- backup được khôi phục nếu live config đã thay đổi;
- DHCP được restart;
- script dừng trước khi xóa HEV instance.

## Xóa iptables

Mỗi rule được xóa trong vòng `while iptables -C ...`; do đó nếu trước đây vô tình có nhiều rule trùng, script sẽ xóa hết.

## Điểm cần lưu ý

- Backup instance được giữ trong `/root`, có thể chứa credential.
- Script source `instance.conf` để hỗ trợ interface khác với default.
- Nếu lỗi xảy ra sau khi DHCP đã thành công nhưng trong giai đoạn xóa network, trap vẫn có thể restore DHCP cũ dù một số tài nguyên HEV đã bị xóa. Đây là tình huống hiếm nhưng là một điểm có thể cải tiến bằng transaction state chi tiết hơn.
- `systemctl disable --now` loại instance khỏi auto-start.

## Toàn bộ source code

```bash
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

---

# Chapter 6 – `cleanup-hev-backups.sh`

## Mục đích

Giới hạn số lượng backup tự động để tránh tăng dung lượng vô hạn.

## Chính sách giữ lại

```text
KEEP_CONFIG_BACKUPS=10
KEEP_REMOVED_INSTANCES=5
```

Script giữ:

- 10 backup `dhcpd.conf`;
- 10 backup `config.yml` trên mỗi instance;
- 10 backup `instance.conf` trên mỗi instance;
- 5 thư mục backup instance đã xóa.

## Hàm `cleanup_files`

1. Nhận glob pattern và số lượng cần giữ.
2. Dùng `find -printf '%T@ %p\n'` để lấy thời gian sửa và path.
3. Sort giảm dần, file mới nhất đứng trước.
4. Nếu số file lớn hơn `keep`, xóa từ index `keep` trở đi.

## Hàm `cleanup_directories`

Hoạt động tương tự nhưng áp dụng cho thư mục `/root/hev-removed-*`.

## Điểm tốt

- Sử dụng array và quote path khi xóa.
- Có `--` trước path trong `rm`.
- Không lỗi khi pattern không có file phù hợp.
- Retention theo từng instance, không gom tất cả instance chung một quota.

## Điểm cần lưu ý

- Dựa vào modification time, không dựa trực tiếp vào timestamp trong tên.
- Script chỉ quản lý backup do các management script tạo; không xóa các full backup thủ công trong `/root/proxy-gateway-backups`.
- Chạy với quyền root vì cần đọc/xóa trong `/etc` và `/root`.

## Toàn bộ source code

```bash
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

---

# Chapter 7 – Quan hệ giữa các script

## Add VM

```text
app.py
  ├─ add-hev-instance.sh
  │    ├─ tạo /etc/hev/<instance>/config.yml
  │    ├─ tạo instance.conf
  │    ├─ thêm rt_tables
  │    └─ start systemd service
  │          └─ HEV binary
  │                └─ ExecStartPost: hev-instance-up.sh
  │                      ├─ proxy /32 WAN route
  │                      ├─ per-VM routing table
  │                      ├─ source ip rule
  │                      ├─ FORWARD rules
  │                      └─ fail-close REJECT
  └─ set-dhcp-reservation.sh
       ├─ backup dhcpd.conf
       ├─ append/update host reservation
       ├─ dhcpd -t
       └─ restart DHCP
```

## Change Proxy

```text
app.py
  └─ change-proxy.sh
       ├─ test TCP
       ├─ backup config
       ├─ update socks5 section
       ├─ update PROXY_IP metadata
       ├─ restart HEV
       └─ restore backup on failure
```

## Delete VM

```text
app.py
  └─ remove-hev-instance.sh
       ├─ backup instance
       ├─ remove DHCP reservation
       ├─ stop/disable service
       ├─ delete rule/table/firewall/interface
       ├─ delete rt_tables entry
       └─ delete /etc/hev/<instance>
```

# Chapter 8 – Điểm cần cải tiến trong phiên bản sau

1. Tách các giá trị hardcode WAN/LAN ra `gateway.conf`.
2. Validate proxy IP trực tiếp trong Bash script, không chỉ dựa vào Web UI.
3. Kiểm tra SOCKS5 authentication thực tế thay vì chỉ TCP connect.
4. Cân nhắc YAML parser chuyên dụng cho `change-proxy.sh`.
5. Thêm file lock để ngăn hai thao tác đồng thời sửa `dhcpd.conf`.
6. Thêm transaction state chi tiết hơn cho thao tác Delete.
7. Thêm automated tests cho regex DHCP host block.
8. Thêm lệnh diagnostic chuẩn không hiển thị credential.
9. Cân nhắc nftables abstraction trong phiên bản tương lai.
10. Đồng nhất ngôn ngữ message giữa tiếng Anh và tiếng Việt.

# End of Document

---

# Bổ sung v1.0.3 - DNS riêng theo từng VM và DNS fail-close

v1.0.3 bổ sung một Unbound instance riêng cho mỗi VM. DNS của VM được redirect
từ port 53 sang listener riêng trên `10.0.1.1`, sau đó Unbound dùng source IP
`198.19.<INSTANCE>.1` và policy-route truy vấn upstream qua đúng routing table
`hev<INSTANCE>`.

```text
DNS_SOURCE_IP=198.19.<INSTANCE>.1
DNS_PORT=53000+INSTANCE
DNS_RULE_PRIORITY=INSTANCE+1000
DNS_BLOCK_PRIORITY=INSTANCE+1100
DNS_SERVICE=proxy-gateway-dns@<INSTANCE>.service
DNS_CONFIG=/etc/unbound/proxy-gateway/vm<INSTANCE>.conf
```

Ví dụ VM104 dùng `10.0.1.1:53104`, source `198.19.104.1`, table `hev104`.

`add-hev-instance.sh` tạo DNS config, source IP, DNS policy rules, UDP/TCP
redirect và bật `proxy-gateway-dns@<INSTANCE>.service`. Rollback phải dọn cả
HEV và DNS state.

`remove-hev-instance.sh` dừng/disable DNS service và xóa DNS config, source IP,
DNS policy rules, redirect rules cùng tài nguyên HEV.

`dns-instance-up.sh` được systemd gọi trước Unbound để dựng lại runtime DNS
state sau reboot/service restart.

Template service:

```text
/etc/systemd/system/proxy-gateway-dns@.service
```

Unbound per-VM sử dụng TCP upstream, `outgoing-interface:
198.19.<INSTANCE>.1`, `do-ip6: no`, `forward-first: no` và:

```yaml
remote-control:
    control-enable: no
```

Việc tắt remote-control tránh nhiều Unbound instance tranh control port
`127.0.0.1:8953`.

## Kiểm tra

```bash
systemctl is-active proxy-gateway-dns@104
sudo ss -lntup | grep 53104
ip addr show lo | grep 198.19.104.1
ip rule | grep -E '10\.0\.1\.104|198\.19\.104\.1'
ip route get 8.8.8.8 from 198.19.104.1
dig @10.0.1.1 -p 53104 dnsleaktest.com
sudo iptables -t nat -S PREROUTING | grep -E '10\.0\.1\.104|53104'
```

Khi HEV hoạt động, route phải chọn `dev hev104 table hev104` và DNS resolve
thành công.

## DNS fail-close

```bash
sudo systemctl stop hev-socks5-tunnel@104
ip route get 8.8.8.8 from 198.19.104.1
```

Kết quả route phải là `Network is unreachable`. Một truy vấn DNS mới từ VM104
phải thất bại và Internet cũng phải thất bại; DNS không được fallback trực tiếp
ra WAN.

Sau:

```bash
sudo systemctl start hev-socks5-tunnel@104
```

DNS và Internet phải phục hồi qua proxy.

Lưu ý: DNS do chính Ubuntu gateway hoặc ứng dụng quản trị sinh ra có thể vẫn
xuất hiện trên WAN. Khi kiểm tra leak của VM cần lọc theo IP VM và
`198.19.<INSTANCE>.1`.
