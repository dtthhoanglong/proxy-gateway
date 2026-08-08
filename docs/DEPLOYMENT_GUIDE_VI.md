# Hướng dẫn triển khai Proxy Gateway --- Bản tiếng Việt

**Nền tảng mục tiêu:** Ubuntu Server 22.04 LTS\
**Kiến trúc:** 1 Ubuntu Gateway, tối đa 20 VM (VM101--VM120), mỗi VM
dùng một SOCKS5 riêng qua HEV SOCKS5 Tunnel\
**Mạng LAN mặc định:** `10.0.1.0/24` --- Gateway `10.0.1.1`\
**DNS:** DNS riêng từng VM bằng Unbound, có DNS fail-close

> Tài liệu này là bản tiếng Việt hoàn chỉnh, viết lại theo quy trình đã
> kiểm thử thực tế trên VMware Workstation. Tên lệnh, tên file, tên
> service và thông báo kỹ thuật được giữ nguyên bằng tiếng Anh vì đó là
> tên thật trong hệ thống.

------------------------------------------------------------------------

# Mục lục

1.  Tắt Cloud-Init quản lý mạng
2.  Xác định và cấu hình WAN/LAN
3.  Bật IPv4 Forwarding
4.  Cài đặt và cấu hình ISC DHCP Server
5.  Cài HEV SOCKS5 Tunnel
6.  Cài các gói phụ thuộc của Proxy Gateway
7.  Tải source code và cài 7 script quản lý
8.  Tạo cấu hình mạng dùng chung `network.conf`
9.  Cài các systemd service
10. Cài Web UI
11. Kiểm tra toàn bộ trước khi Add VM
12. Tạo và kiểm thử VM101
13. Quản lý nhiều VM
14. Backup, cập nhật và bảo trì
15. Xử lý sự cố

------------------------------------------------------------------------

# Chương 1 --- Tắt Cloud-Init quản lý mạng và bỏ chờ WAN khi boot

Ubuntu Server có thể để Cloud-Init tạo lại cấu hình mạng sau khi reboot.
Proxy Gateway cần cấu hình mạng ổn định, vì vậy chỉ tắt phần quản lý
network của Cloud-Init.

``` bash
sudo mkdir -p /etc/cloud/cloud.cfg.d

echo 'network: {config: disabled}' | \
    sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
```

Kiểm tra:

``` bash
cat /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
```

Kết quả phải là:

``` text
network: {config: disabled}
```

Không cần gỡ toàn bộ Cloud-Init.

## 1.1 Tắt dịch vụ chờ mạng khi khởi động

Trên Ubuntu Server dùng `systemd-networkd`, dịch vụ
`systemd-networkd-wait-online.service` có thể làm máy chờ khoảng 2 phút
nếu cổng WAN không có link hoặc không nhận được DHCP. Proxy Gateway phải
vẫn boot bình thường khi WAN bị rút dây, vì vậy tắt và mask dịch vụ này:

``` bash
sudo systemctl disable systemd-networkd-wait-online.service
sudo systemctl mask systemd-networkd-wait-online.service
```

Kiểm tra:

``` bash
systemctl is-enabled systemd-networkd-wait-online.service
```

Kết quả mong đợi:

``` text
masked
```

Nên kiểm thử bằng cách ngắt kết nối WAN rồi reboot. Ubuntu Server phải
boot thẳng vào hệ thống mà không dừng ở thông báo `Wait for Network to be Configured`.

------------------------------------------------------------------------

# Chương 2 --- Xác định và cấu hình WAN/LAN

Proxy Gateway sử dụng hai interface:

-   **WAN**: nối modem/router và có default route ra Internet.
-   **LAN**: nối mạng riêng dành cho các VM, địa chỉ cố định
    `10.0.1.1/24`.

Tên interface **không được hard-code**. Ví dụ máy thật có thể là
`enp2s0/enp3s0`, trong VMware có thể là `ens33/ens37`.

## 2.1 Xác định interface

``` bash
ip -br a
ip route
```

Xác định interface nào nối modem/router và interface nào dùng cho LAN
VM.

Ví dụ VMware đã kiểm thử:

``` text
LAN_IF=ens33
WAN_IF=ens37
LAN_IP=10.0.1.1
WAN_GW=192.168.2.1
```

`192.168.2.1` là gateway của modem; địa chỉ WAN của Ubuntu có thể thay
đổi theo DHCP và không cần cố định trong runtime script.

## 2.2 Xác định và mở file Netplan đang sử dụng

Liệt kê các file Netplan hiện có:

``` bash
ls -l /etc/netplan/
```

Trên Ubuntu Server clean install thường gặp file như:

``` text
/etc/netplan/50-cloud-init.yaml
```

hoặc:

``` text
/etc/netplan/00-installer-config.yaml
```

Mở **đúng file đang có trên máy**. Ví dụ:

``` bash
sudo nano /etc/netplan/50-cloud-init.yaml
```

Nếu máy dùng tên file khác, thay `50-cloud-init.yaml` bằng tên thật.
Interface LAN có thể chưa xuất hiện trong file Netplan mặc định; khi đó
phải tự thêm LAN vào file này. Việc LAN chưa có trong Netplan không liên
quan đến việc đã cài DHCP Server hay chưa.

## 2.3 Cấu hình WAN và LAN trong Netplan

Thay `WAN_INTERFACE` và `LAN_INTERFACE` bằng tên interface thật đã xác
định ở mục 2.1:

``` yaml
network:
  version: 2
  ethernets:
    WAN_INTERFACE:
      dhcp4: true
      optional: true

    LAN_INTERFACE:
      dhcp4: false
      addresses:
        - 10.0.1.1/24
      optional: true
```

Ví dụ: nếu `ens33` là WAN và `ens34` là LAN thì thay đúng hai tên đó
trong file Netplan.

Áp dụng:

``` bash
sudo netplan generate
sudo netplan apply
```

Nếu xuất hiện cảnh báo về Open vSwitch nhưng `netplan generate` và
`netplan apply` không báo lỗi cấu hình, có thể tiếp tục nếu hệ thống
không sử dụng Open vSwitch.

Kiểm tra bắt buộc trước khi sang chương DHCP:

``` bash
ip -br a
ip route
```

LAN phải có `10.0.1.1/24` và WAN phải có default route. **Không tiếp tục
cài/cấu hình DHCP nếu interface LAN chưa có `10.0.1.1/24`.**

------------------------------------------------------------------------

# Chương 3 --- Bật IPv4 Forwarding

``` bash
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-proxy-gateway.conf
sudo sysctl --system
```

Kiểm tra:

``` bash
sysctl net.ipv4.ip_forward
```

Kết quả:

``` text
net.ipv4.ip_forward = 1
```

------------------------------------------------------------------------

# Chương 4 --- Cài đặt và cấu hình ISC DHCP Server

## 4.1 Cài đặt

``` bash
sudo apt update
sudo apt install -y isc-dhcp-server
```

## 4.2 Chỉ định đúng interface LAN

Mở:

``` bash
sudo nano /etc/default/isc-dhcp-server
```

Đặt:

``` text
INTERFACESv4="LAN_INTERFACE"
INTERFACESv6=""
```

Ví dụ trên VMware đã kiểm thử:

``` text
INTERFACESv4="ens33"
```

Không được trỏ DHCP vào WAN. Nếu trỏ nhầm WAN, `dhcpd` sẽ báo kiểu
`No subnet declaration for ...` và
`Not configured to listen on any interfaces!`.

## 4.3 Cấu hình DHCP

Với clean install, file `/etc/dhcp/dhcpd.conf` có nhiều cấu hình mẫu mặc
định dễ gây nhầm lẫn. Mở file:

``` bash
sudo nano /etc/dhcp/dhcpd.conf
```

Xóa toàn bộ nội dung cũ và thay bằng cấu hình sau:

``` text
authoritative;

default-lease-time 600;
max-lease-time 7200;

subnet 10.0.1.0 netmask 255.255.255.0 {
    option routers 10.0.1.1;
    option subnet-mask 255.255.255.0;
    option domain-name-servers 10.0.1.1;
    range 10.0.1.100 10.0.1.200;
}
```

DNS của VM phải là **gateway `10.0.1.1`**; không cấp trực tiếp `8.8.8.8`
hoặc `1.1.1.1`. DNS per-VM và DNS fail-close chỉ hoạt động đúng khi
client gửi DNS tới `10.0.1.1`.

Lưu file rồi kiểm tra syntax:

``` bash
sudo dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf
```

Nếu lệnh trên không báo lỗi syntax, mới khởi động DHCP:

``` bash
sudo systemctl restart isc-dhcp-server
sudo systemctl enable isc-dhcp-server
systemctl status isc-dhcp-server --no-pager
```

Nếu DHCP không start, kiểm tra ngay:

``` bash
ip -br a
grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server
sudo journalctl -u isc-dhcp-server -n 50 --no-pager
```

Interface LAN phải đang có `10.0.1.1/24` trước khi `isc-dhcp-server` có
thể bind và hoạt động.

------------------------------------------------------------------------

# Chương 5 --- Cài HEV SOCKS5 Tunnel

Proxy Gateway đã được kiểm thử với **HEV SOCKS5 Tunnel 2.14.4** trên
Linux x86_64. Khi triển khai, ưu tiên binary release dựng sẵn; không cần
build source.

Kiểm tra kiến trúc:

``` bash
uname -m
```

Với x86_64:

``` bash
sudo apt update
sudo apt install -y wget

cd /tmp
wget -O hev-socks5-tunnel \
  https://github.com/heiher/hev-socks5-tunnel/releases/download/2.14.4/hev-socks5-tunnel-linux-x86_64

sudo install -m 755 \
  /tmp/hev-socks5-tunnel \
  /usr/local/bin/hev-socks5-tunnel
```

Kiểm tra:

``` bash
command -v hev-socks5-tunnel
/usr/local/bin/hev-socks5-tunnel --version
```

Tạo thư mục runtime:

``` bash
sudo mkdir -p /etc/hev
```

> Không chạy `add-hev-instance.sh` ở chương này. Instance sẽ được tạo
> sau khi toàn bộ runtime, DNS và Web UI đã cài xong.

------------------------------------------------------------------------

# Chương 6 --- Cài các gói phụ thuộc

Phần này phải hoàn thành **trước khi cài/chạy các script quản lý**.

``` bash
sudo apt update
sudo apt install -y \
  git \
  netcat-openbsd \
  iptables \
  python3 \
  python3-pip \
  python3-flask \
  gunicorn \
  unbound \
  dnsutils
```

Proxy Gateway không dùng default Unbound service. Mỗi VM có một Unbound
instance riêng.

``` bash
sudo systemctl disable --now unbound 2>/dev/null || true
```

Kiểm tra:

``` bash
command -v nc
command -v iptables
command -v python3
command -v unbound
command -v unbound-checkconf
command -v dig
```

Tất cả phải trả về executable path hợp lệ.

------------------------------------------------------------------------

# Chương 7 --- Tải source và cài 7 script quản lý

## 7.1 Tải source code

``` bash
cd ~
git clone https://github.com/dtthhoanglong/proxy-gateway.git
cd proxy-gateway
```

Khi triển khai một release chính thức, checkout đúng tag của release đó.
Nếu đang kiểm thử code mới nhất trước khi tạo tag, giữ branch `main` và
xác nhận commit đang dùng.

``` bash
git status
git log -1 --oneline --decorate
```

## 7.2 Cài đủ 7 script

Từ thư mục `~/proxy-gateway`:

``` bash
sudo install -o root -g root -m 750 \
  scripts/add-hev-instance.sh \
  scripts/change-proxy.sh \
  scripts/cleanup-hev-backups.sh \
  scripts/hev-instance-up.sh \
  scripts/remove-hev-instance.sh \
  scripts/set-dhcp-reservation.sh \
  scripts/dns-instance-up.sh \
  /usr/local/sbin/
```

Bảy script bắt buộc là:

1.  `add-hev-instance.sh`
2.  `change-proxy.sh`
3.  `cleanup-hev-backups.sh`
4.  `hev-instance-up.sh`
5.  `remove-hev-instance.sh`
6.  `set-dhcp-reservation.sh`
7.  `dns-instance-up.sh`

## 7.3 Kiểm tra syntax

``` bash
for file in \
  /usr/local/sbin/add-hev-instance.sh \
  /usr/local/sbin/change-proxy.sh \
  /usr/local/sbin/cleanup-hev-backups.sh \
  /usr/local/sbin/hev-instance-up.sh \
  /usr/local/sbin/remove-hev-instance.sh \
  /usr/local/sbin/set-dhcp-reservation.sh \
  /usr/local/sbin/dns-instance-up.sh; do
    echo "Checking $file"
    sudo bash -n "$file" || exit 1
done
```

## 7.4 Kiểm tra quyền

Do script có quyền `750 root:root`, khi kiểm tra executable phải dùng
`sudo test -x`, không dùng `[ -x "$file" ]` dưới user thường.

``` bash
for file in \
  /usr/local/sbin/add-hev-instance.sh \
  /usr/local/sbin/change-proxy.sh \
  /usr/local/sbin/cleanup-hev-backups.sh \
  /usr/local/sbin/hev-instance-up.sh \
  /usr/local/sbin/remove-hev-instance.sh \
  /usr/local/sbin/set-dhcp-reservation.sh \
  /usr/local/sbin/dns-instance-up.sh; do
    if sudo test -x "$file"; then
        echo "OK: $file"
    else
        echo "MISSING OR NOT EXECUTABLE: $file"
    fi
done
```

Không đổi permission `750` chỉ để user thường chạy được phép kiểm tra.

## 7.5 Chức năng của các script --- chỉ để tham khảo

> **Mục này chỉ cung cấp thông tin. Không có lệnh nào trong mục này bắt
> buộc phải chạy trong quá trình cài đặt.** Web UI sẽ gọi các script
> quản lý khi Add VM, Change Proxy hoặc Remove VM.

-   `add-hev-instance.sh`: tạo HEV instance, routing table, DNS config
    và service cho VM.
-   `hev-instance-up.sh`: dựng route, policy rule, FORWARD và direct-WAN
    fail-close sau khi tunnel xuất hiện.
-   `change-proxy.sh`: đổi SOCKS5 của instance và rollback khi lỗi.
-   `set-dhcp-reservation.sh`: tạo/cập nhật DHCP reservation theo MAC.
-   `remove-hev-instance.sh`: xóa instance, DNS, DHCP, route và firewall
    liên quan.
-   `dns-instance-up.sh`: dựng source IP và policy routing cho DNS
    per-VM, gồm DNS fail-close.
-   `cleanup-hev-backups.sh`: dọn các backup cũ.

------------------------------------------------------------------------

# Chương 8 --- Tạo cấu hình mạng dùng chung

Runtime script không được chứa cố định tên NIC như `enp1s0`, `wlp2s0`,
`ens33` hoặc `ens37`. Cấu hình thật của từng máy nằm tại:

``` text
/etc/proxy-gateway/network.conf
```

Tạo thư mục:

``` bash
sudo mkdir -p /etc/proxy-gateway
```

Có thể dùng template trong source:

``` bash
sudo cp config/network.conf.example /etc/proxy-gateway/network.conf
sudo chmod 644 /etc/proxy-gateway/network.conf
sudo nano /etc/proxy-gateway/network.conf
```

Ví dụ trên VMware đã kiểm thử:

``` bash
LAN_IF="ens33"
WAN_IF="ens37"

LAN_IP="10.0.1.1"
LAN_NET="10.0.1.0/24"

WAN_GW="192.168.2.1"
```

Trên máy vật lý, thay `ens33/ens37` bằng tên interface thật.

Kiểm tra:

``` bash
cat /etc/proxy-gateway/network.conf
```

Các script `add-hev-instance.sh` và `remove-hev-instance.sh` đọc file
này. `instance.conf` của mỗi VM sẽ lưu lại interface/network tương ứng
để các script runtime sử dụng.

------------------------------------------------------------------------

# Chương 9 --- Cài các systemd service

Proxy Gateway sử dụng ba unit:

``` text
hev-socks5-tunnel@.service
proxy-gateway-dns@.service
proxy-gateway-ui.service
```

Từ `~/proxy-gateway`:

``` bash
sudo install -o root -g root -m 644 \
  systemd/hev-socks5-tunnel@.service \
  /etc/systemd/system/hev-socks5-tunnel@.service

sudo install -o root -g root -m 644 \
  systemd/proxy-gateway-dns@.service \
  /etc/systemd/system/proxy-gateway-dns@.service

sudo install -o root -g root -m 644 \
  systemd/proxy-gateway-ui.service \
  /etc/systemd/system/proxy-gateway-ui.service
```

**Bắt buộc** cho systemd đọc lại unit mới:

``` bash
sudo systemctl daemon-reload
```

Kiểm tra cả ba:

``` bash
systemctl cat hev-socks5-tunnel@.service
systemctl cat proxy-gateway-dns@.service
systemctl cat proxy-gateway-ui.service
```

Không start `hev-socks5-tunnel@101` hoặc `proxy-gateway-dns@101` lúc
này. Các instance chỉ được start sau khi Add VM tạo đủ file cấu hình.

------------------------------------------------------------------------

# Chương 10 --- Cài Web UI

## 10.1 Kiểm tra dependency Web UI

`python3-flask` và `gunicorn` đã được cài bắt buộc ở Chương 6. Không phụ
thuộc vào việc repository có `webui/requirements.txt` hay không.

Kiểm tra:

``` bash
command -v gunicorn
python3 -c 'import flask; print(flask.__version__)'
```

`command -v gunicorn` phải trả về executable path hợp lệ (thường là
`/usr/bin/gunicorn`). Nếu thiếu, cài lại:

``` bash
sudo apt install -y python3-flask gunicorn
```

Từ `~/proxy-gateway`, kiểm tra source Web UI:

``` bash
ls -la webui
```

Tạo runtime directory và chép Web UI:

``` bash
sudo mkdir -p /opt/proxy-gateway-ui
sudo cp -a webui/. /opt/proxy-gateway-ui/
```

Kiểm tra Python:

``` bash
python3 -m py_compile /opt/proxy-gateway-ui/app.py
```

Sau khi application đã có đầy đủ:

``` bash
sudo systemctl enable --now proxy-gateway-ui
```

Kiểm tra:

``` bash
systemctl status proxy-gateway-ui --no-pager
curl http://10.0.1.1:8080/health
```

Health endpoint phải trả trạng thái OK theo ứng dụng.

> Web UI chạy với quyền hệ thống để gọi management scripts. Chỉ mở Web
> UI trên LAN tin cậy, không expose trực tiếp ra Internet.

------------------------------------------------------------------------

# Chương 11 --- Kiểm tra toàn bộ trước khi Add VM

## 11.1 Network

``` bash
ip -br a
ip route
cat /etc/proxy-gateway/network.conf
```

Xác nhận LAN có `10.0.1.1/24`, WAN có default route và `network.conf`
khớp interface thật.

## 11.2 Forwarding và DHCP

``` bash
sysctl net.ipv4.ip_forward
systemctl is-active isc-dhcp-server
sudo dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf
```

## 11.3 HEV

``` bash
ls -l /usr/local/bin/hev-socks5-tunnel
/usr/local/bin/hev-socks5-tunnel --version
```

## 11.4 Bảy script

``` bash
sudo ls -l \
  /usr/local/sbin/add-hev-instance.sh \
  /usr/local/sbin/change-proxy.sh \
  /usr/local/sbin/cleanup-hev-backups.sh \
  /usr/local/sbin/hev-instance-up.sh \
  /usr/local/sbin/remove-hev-instance.sh \
  /usr/local/sbin/set-dhcp-reservation.sh \
  /usr/local/sbin/dns-instance-up.sh
```

## 11.5 Ba systemd unit

``` bash
systemctl cat hev-socks5-tunnel@.service
systemctl cat proxy-gateway-dns@.service
systemctl cat proxy-gateway-ui.service
```

## 11.6 Unbound

``` bash
command -v unbound
command -v unbound-checkconf
systemctl is-active unbound 2>&1 || true
```

Default `unbound.service` nên `inactive`; DNS per-VM sẽ chạy qua
`proxy-gateway-dns@<VM>.service`.

------------------------------------------------------------------------

# Chương 12 --- Tạo và kiểm thử VM101

Nên kiểm thử một VM hoàn chỉnh trước khi triển khai VM102--VM120.

## 12.1 Chuẩn bị VM

VM phải nối vào mạng LAN của Proxy Gateway. Trong VMware Workstation, VM
client và NIC LAN của Ubuntu Gateway phải nằm trên cùng VMnet LAN.

VM101 dùng DHCP. Web UI sẽ tạo reservation để VM nhận:

``` text
IP:      10.0.1.101
Gateway: 10.0.1.1
DNS:     10.0.1.1
```

Mỗi VM phải có MAC riêng.

## 12.2 Add VM bằng Web UI

Dùng chức năng **Add VM** và nhập:

-   Instance/VM number: `101`
-   MAC của VM101
-   SOCKS5 IP
-   SOCKS5 port
-   Username
-   Password

Không cần chạy `add-hev-instance.sh` thủ công khi sử dụng Web UI.

## 12.3 Kiểm tra Ubuntu sau khi Add VM

``` bash
systemctl status hev-socks5-tunnel@101 --no-pager
systemctl status proxy-gateway-dns@101 --no-pager
ip link show hev101
cat /etc/hev/101/instance.conf
ip rule
ip route show table hev101
sudo iptables -L FORWARD -n -v --line-numbers
sudo iptables -t nat -L PREROUTING -n -v --line-numbers
```

Bảng `hev101` phải có default route qua `hev101` và route LAN qua
interface LAN.

## 12.4 Kiểm tra DHCP/DNS trên Windows VM

``` cmd
ipconfig /all
nslookup google.com
```

Phải thấy:

``` text
IPv4 Address:    10.0.1.101
Default Gateway: 10.0.1.1
DHCP Server:     10.0.1.1
DNS Servers:     10.0.1.1
```

Nếu DNS Server vẫn là `8.8.8.8` hoặc `1.1.1.1`, sửa `dhcpd.conf` để cấp
`10.0.1.1`, restart DHCP và renew lease.

## 12.5 Kiểm tra public IP

Trên PowerShell của VM:

``` powershell
(Invoke-WebRequest -UseBasicParsing https://ifconfig.me/ip).Content
```

IP trả về phải đúng IP public của SOCKS5 đã gán cho VM101, không phải
WAN public IP của modem.

## 12.6 Kiểm tra DNS redirect

Trên Gateway:

``` bash
sudo iptables -t nat -L PREROUTING -n -v --line-numbers
sudo ss -lntup | grep 53101
ip rule
ip route show table hev101
```

Sau khi VM chạy `nslookup`, counter UDP/53 của VM101 phải tăng. Unbound
VM101 phải listen trên `10.0.1.1:53101`.

## 12.7 Kiểm tra fail-close

Dừng HEV101:

``` bash
sudo systemctl stop hev-socks5-tunnel@101
systemctl is-active hev-socks5-tunnel@101
```

Trên VM101:

``` cmd
nslookup google.com
```

DNS phải lỗi. HTTPS ra Internet cũng phải lỗi. Kiểm tra routing từ
Gateway:

``` bash
ip route get 1.1.1.1 from 10.0.1.101
```

Khi HEV không tồn tại và bảng instance không có default route, kết quả
phải là `Network is unreachable`, không được fallback qua WAN.

Có thể dùng:

``` bash
sudo tcpdump -ni "$WAN_IF" host 1.1.1.1
```

để xác nhận không có traffic VM101 thoát trực tiếp ra WAN.

## 12.8 Kiểm tra recovery

``` bash
sudo systemctl start hev-socks5-tunnel@101
```

Không restart DNS và không renew DHCP. VM phải tự phục hồi DNS và
Internet. Kiểm tra lại public IP SOCKS5.

## 12.9 Kiểm tra reboot Gateway

Trước reboot:

``` bash
systemctl is-enabled hev-socks5-tunnel@101
systemctl is-enabled proxy-gateway-dns@101
systemctl is-enabled proxy-gateway-ui
```

Cả ba phải là `enabled`.

Reboot:

``` bash
sudo reboot
```

Sau khi máy lên, **không start service thủ công**, kiểm tra:

``` bash
systemctl is-active hev-socks5-tunnel@101
systemctl is-active proxy-gateway-dns@101
systemctl is-active proxy-gateway-ui
ip -br a
ip rule
ip route show table hev101
sudo iptables -L FORWARD -n -v --line-numbers
sudo iptables -t nat -L PREROUTING -n -v --line-numbers
```

VM101 phải tự resolve DNS và public IP vẫn là SOCKS5 đã gán.

------------------------------------------------------------------------

# Chương 13 --- Quản lý nhiều VM

Chỉ triển khai thêm sau khi VM101 vượt qua đầy đủ kiểm thử ở Chương 12.

Quy ước:

``` text
VM101 -> 10.0.1.101 -> hev101 -> SOCKS5 #101
VM102 -> 10.0.1.102 -> hev102 -> SOCKS5 #102
...
VM120 -> 10.0.1.120 -> hev120 -> SOCKS5 #120
```

Mỗi VM phải có:

-   MAC riêng;
-   DHCP reservation riêng;
-   `/etc/hev/<VM>/config.yml`;
-   `/etc/hev/<VM>/instance.conf`;
-   HEV service riêng;
-   Unbound DNS service riêng;
-   policy rule riêng;
-   routing table riêng;
-   direct-WAN fail-close riêng.

Dùng Web UI cho các thao tác thường ngày: Add VM, Change Proxy, Remove
VM, Start/Stop/Restart instance.

Sau khi thêm mỗi VM, kiểm tra public IP và fail-close trước khi thêm VM
tiếp theo.

------------------------------------------------------------------------

# Chương 14 --- Backup, cập nhật và bảo trì

Các dữ liệu quan trọng cần backup gồm:

``` text
/etc/hev/
/etc/dhcp/dhcpd.conf
/etc/default/isc-dhcp-server
/etc/proxy-gateway/network.conf
/etc/unbound/proxy-gateway/
/etc/systemd/system/hev-socks5-tunnel@.service
/etc/systemd/system/proxy-gateway-dns@.service
/etc/systemd/system/proxy-gateway-ui.service
/usr/local/sbin/
/opt/proxy-gateway-ui/
```

Các file HEV có thể chứa username/password SOCKS5. Không đưa backup
production hoặc credential lên repository public.

Khi cập nhật source/script:

``` bash
cd ~/proxy-gateway
git status
git pull --ff-only
```

Sau khi chép script mới, luôn kiểm tra `bash -n`. Sau khi thay đổi
systemd unit, luôn chạy:

``` bash
sudo systemctl daemon-reload
```

Không tạo tag release mới trước khi code và tài liệu của release đã được
kiểm thử.

------------------------------------------------------------------------

# Chương 15 --- Xử lý sự cố

## 15.1 DHCP không start

Kiểm tra:

``` bash
grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server
ip -br a
sudo dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf
sudo journalctl -u isc-dhcp-server -n 50 --no-pager
```

Nếu log báo `No subnet declaration for <WAN>` thì rất có thể
`INTERFACESv4` đang trỏ nhầm WAN.

## 15.2 Add VM báo thiếu Unbound

``` bash
command -v unbound
command -v unbound-checkconf
```

Nếu thiếu:

``` bash
sudo apt install -y unbound
sudo systemctl disable --now unbound 2>/dev/null || true
```

## 15.3 HEV báo không tìm thấy interface cũ

Ví dụ:

``` text
Cannot find device "wlp2s0"
```

Kiểm tra:

``` bash
cat /etc/proxy-gateway/network.conf
cat /etc/hev/101/instance.conf
```

Runtime script phải dùng `network.conf`; không được hard-code interface
của máy khác.

## 15.4 VM có Internet qua proxy nhưng DNS lỗi

Trên VM kiểm tra `ipconfig /all`. DNS phải là `10.0.1.1`.

Trên Gateway:

``` bash
systemctl status proxy-gateway-dns@101 --no-pager
sudo ss -lntup | grep 53101
sudo iptables -t nat -L PREROUTING -n -v --line-numbers
```

## 15.5 Thu thập snapshot chẩn đoán

``` bash
echo '=== NETWORK CONFIG ==='
cat /etc/proxy-gateway/network.conf

echo '=== INTERFACES ==='
ip -br a

echo '=== ROUTES ==='
ip route

echo '=== RULES ==='
ip rule

echo '=== FORWARDING ==='
sysctl net.ipv4.ip_forward

echo '=== DHCP ==='
systemctl is-active isc-dhcp-server

echo '=== HEV SERVICES ==='
systemctl list-units 'hev-socks5-tunnel@*.service' --all --no-pager

echo '=== DNS SERVICES ==='
systemctl list-units 'proxy-gateway-dns@*.service' --all --no-pager

echo '=== WEB UI ==='
systemctl is-active proxy-gateway-ui
```

Không đăng công khai nội dung `/etc/hev/*/config.yml` nếu chưa xóa
credential SOCKS5.

------------------------------------------------------------------------

# Checklist triển khai cuối cùng

-   [ ] Cloud-Init không còn quản lý network.
-   [ ] WAN và LAN được xác định đúng.
-   [ ] LAN giữ `10.0.1.1/24`.
-   [ ] `/etc/proxy-gateway/network.conf` khớp phần cứng hiện tại.
-   [ ] IPv4 forwarding = `1`.
-   [ ] ISC DHCP Server chạy trên LAN.
-   [ ] DHCP cấp gateway `10.0.1.1` và DNS `10.0.1.1`.
-   [ ] HEV binary đã cài và chạy được.
-   [ ] Unbound đã cài; default `unbound.service` không chạy.
-   [ ] Đủ 7 management script, quyền `750 root:root`.
-   [ ] Đủ 3 systemd unit và đã `daemon-reload`.
-   [ ] Web UI hoạt động.
-   [ ] VM101 nhận đúng IP/MAC reservation.
-   [ ] VM101 resolve DNS qua `10.0.1.1`.
-   [ ] VM101 ra đúng public IP của SOCKS5.
-   [ ] HEV chết thì DNS/Internet của VM tương ứng fail-close.
-   [ ] Không fallback traffic trực tiếp qua WAN.
-   [ ] HEV start lại thì VM tự recovery.
-   [ ] Reboot Gateway thì HEV, DNS và Web UI tự phục hồi.
-   [ ] Chỉ sau khi VM101 PASS mới triển khai VM102--VM120.

------------------------------------------------------------------------

# Ghi chú về ngôn ngữ

Bản này chủ động dùng tiếng Việt cho toàn bộ phần giải thích, tiêu đề,
cảnh báo và quy trình. Các thành phần sau vẫn giữ nguyên tiếng Anh vì là
tên kỹ thuật hoặc chuỗi phải nhập chính xác: tên package, command, file
path, systemd unit, interface, biến cấu hình, output/error message và
tên chức năng trong Web UI.
