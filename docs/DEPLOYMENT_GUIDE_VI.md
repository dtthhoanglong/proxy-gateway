# Hướng dẫn triển khai Proxy Gateway --- Bản tiếng Việt

**Nền tảng mục tiêu:** Ubuntu Server 22.04 LTS\
**Kiến trúc:** 1 Ubuntu Gateway, tối đa 20 VM (VM101--VM120), mỗi VM dùng một SOCKS5 riêng qua HEV SOCKS5 Tunnel\
**Mạng LAN mặc định:** `10.0.1.0/24` và `fd10:0:1::/64` --- Gateway `10.0.1.1` / `fd10:0:1::1`\
**IPv6 client:** RA/SLAAC (Automatic), nhận diện client IPv6 theo MAC\
**DNS:** DNS riêng từng VM bằng Unbound, có DNS fail-close

> Tài liệu này là hướng dẫn triển khai thực tế trên Ubuntu Server 22.04 LTS.
> Từ phiên bản hiện tại, phần cài đặt hệ thống được tự động hóa bằng `install.sh`.
> Các chi tiết kỹ thuật và cấu hình thủ công có thể xem trong `INSTALL_VI.md`.

------------------------------------------------------------------------

# Mục lục

1. Chuẩn bị Ubuntu Server
2. Cài Proxy Gateway tự động
3. Kiểm tra nhanh sau cài đặt
4. Kiểm tra toàn bộ trước khi Add VM
5. Tạo và kiểm thử VM101
6. Quản lý nhiều VM
7. Backup, cập nhật và bảo trì
8. Xử lý sự cố

------------------------------------------------------------------------

# Chương 1 --- Chuẩn bị Ubuntu Server

Cài mới **Ubuntu Server 22.04 LTS** với tối thiểu hai interface mạng:

- **WAN**: nối modem/router và nhận Internet.
- **LAN**: nối mạng riêng dành cho các VM.

Không cần cấu hình thủ công DHCP, radvd, HEV, Unbound, forwarding hoặc Web UI trước khi chạy installer.

Kiểm tra các interface hiện có:

```bash
ip -br link
```

Installer sẽ hiển thị lại danh sách interface và yêu cầu chọn WAN/LAN bằng **số thứ tự**.

------------------------------------------------------------------------

# Chương 2 --- Cài Proxy Gateway tự động

## 2.1 Tải source code

```bash
cd ~
git clone https://github.com/dtthhoanglong/proxy-gateway.git
cd proxy-gateway
```

Nếu thư mục `~/proxy-gateway` đã tồn tại, không clone chồng thêm repository vào bên trong. Hãy dùng repository hiện có hoặc đổi tên/xóa thư mục cũ trước khi clone lại.

## 2.2 Chạy installer

```bash
sudo ./install.sh
```

Installer tự động:

- cài các package cần thiết;
- tắt Cloud-Init quản lý network và bỏ chờ WAN khi boot;
- cài HEV SOCKS5 Tunnel;
- cài các management script;
- cấu hình ISC DHCP Server;
- cài các systemd unit;
- cài Web UI;
- yêu cầu chọn WAN và LAN;
- tạo Netplan và `network.conf`;
- bật IPv4/IPv6 forwarding;
- cấu hình `radvd` cho IPv6 RA/SLAAC;
- khởi động các service;
- chạy self-check sau cài đặt.

Ví dụ:

```text
Available network interfaces:

  1) ens33
  2) ens34

Select WAN interface number: 1
Select LAN interface number: 2
```

Phải nhập **số thứ tự**, không nhập trực tiếp tên interface.

Installer sẽ yêu cầu xác nhận:

```text
Selected: WAN=ens33  LAN=ens34
Apply this network configuration? [y/N]:
```

Nhập `y` nếu lựa chọn đúng.

> Khi chạy `netplan apply`, SSH có thể gián đoạn ngắn.

Cài đặt thành công khi cuối màn hình có:

```text
Proxy Gateway installation complete: PASS
```

------------------------------------------------------------------------

# Chương 3 --- Kiểm tra nhanh sau cài đặt

## 3.1 Network

```bash
ip -br a
ip route
cat /etc/proxy-gateway/network.conf
```

LAN mặc định phải có:

```text
10.0.1.1/24
fd10:0:1::1/64
```

WAN phải có IPv4 default route. Khi ISP/router hỗ trợ IPv6, WAN cũng nhận IPv6/default route qua RA.

## 3.2 Forwarding và service nền

```bash
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding
systemctl is-active isc-dhcp-server
systemctl is-active radvd
systemctl is-active proxy-gateway-ui
```

Hai giá trị forwarding phải là `1`; ba service trên phải là `active`.

## 3.3 Web UI

```bash
curl http://10.0.1.1:8080/health
```

Web UI mặc định:

```text
http://10.0.1.1:8080/
```

Nếu installer kết thúc bằng `PASS` và các kiểm tra trên đúng, tiếp tục Chương 4 trước khi Add VM.

------------------------------------------------------------------------

# Chương 4 --- Kiểm tra toàn bộ trước khi Add VM

## 4.1 Network

``` bash
ip -br a
ip route
cat /etc/proxy-gateway/network.conf
```

Xác nhận LAN có `10.0.1.1/24` và `fd10:0:1::1/64`, WAN có default route và `network.conf`
khớp interface thật.

## 4.2 Forwarding và DHCP

``` bash
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding
systemctl is-active isc-dhcp-server
systemctl is-active radvd
sudo dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf
```

## 4.3 HEV

``` bash
ls -l /usr/local/bin/hev-socks5-tunnel
/usr/local/bin/hev-socks5-tunnel --version
```

## 4.4 Bảy script

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

## 4.5 Ba systemd unit

``` bash
systemctl cat hev-socks5-tunnel@.service
systemctl cat proxy-gateway-dns@.service
systemctl cat proxy-gateway-ui.service
```

## 4.6 Unbound

``` bash
command -v unbound
command -v unbound-checkconf
systemctl is-active unbound 2>&1 || true
```

Default `unbound.service` nên `inactive`; DNS per-VM sẽ chạy qua
`proxy-gateway-dns@<VM>.service`.

------------------------------------------------------------------------

# Chương 5 --- Tạo và kiểm thử VM101

Nên kiểm thử một VM hoàn chỉnh cho từng mode trước khi triển khai VM102--VM120. Proxy Type có thể là `SOCKS5 IPv4` hoặc `SOCKS5 IPv6`; một MAC chỉ nên được gán cho một proxy family tại một thời điểm.

## 5.1 Chuẩn bị VM

VM phải nối vào mạng LAN của Proxy Gateway. Trong VMware Workstation, VM
client và NIC LAN của Ubuntu Gateway phải nằm trên cùng VMnet LAN.

VM101 dùng DHCP. Web UI sẽ tạo reservation để VM nhận:

``` text
IP:      10.0.1.101
Gateway: 10.0.1.1
DNS:     10.0.1.1
```

Mỗi VM phải có MAC riêng.

## 5.2 Add VM bằng Web UI

Dùng chức năng **Add VM** và nhập:

-   Instance/VM number: `101`
-   MAC của VM101
-   SOCKS5 IP
-   SOCKS5 port
-   Username
-   Password
-   Proxy Type: `SOCKS5 IPv4` hoặc `SOCKS5 IPv6`

Không cần chạy `add-hev-instance.sh` thủ công khi sử dụng Web UI.

## 5.3 Kiểm tra Ubuntu sau khi Add VM

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

## 5.4 Kiểm tra DHCP/DNS trên Windows VM

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

## 5.5 Kiểm tra public IP

Trên PowerShell của VM:

``` powershell
(Invoke-WebRequest -UseBasicParsing https://ifconfig.me/ip).Content
```

IP trả về phải đúng IP public của SOCKS5 đã gán cho VM101, không phải
WAN public IP của modem.

## 5.6 Kiểm tra DNS redirect

Trên Gateway:

``` bash
sudo iptables -t nat -L PREROUTING -n -v --line-numbers
sudo ss -lntup | grep 53101
ip rule
ip route show table hev101
```

Sau khi VM chạy `nslookup`, counter UDP/53 của VM101 phải tăng. Unbound
VM101 phải listen trên `10.0.1.1:53101`.

## 5.7 Kiểm tra fail-close

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

## 5.8 Kiểm tra recovery

``` bash
sudo systemctl start hev-socks5-tunnel@101
```

Không restart DNS và không renew DHCP. VM phải tự phục hồi DNS và
Internet. Kiểm tra lại public IP SOCKS5.

## 5.9 Kiểm tra SOCKS5 IPv6 với Windows Automatic

Với một VM được gán `SOCKS5 IPv6`, có thể tắt IPv4 để kiểm thử thuần IPv6 và để **IPv6 = Automatic**, **DNS = Automatic**. Windows phải nhận prefix `fd10:0:1::/64`, default gateway link-local của Gateway và DNS `fd10:0:1::1`.

``` powershell
ipconfig /all
nslookup facebook.com
curl.exe -6 https://ifconfig.co
```

`nslookup` phải dùng DNS `fd10:0:1::1`; `curl -6` phải trả về public IPv6 của SOCKS5 IPv6 đã gán, không phải IPv6 WAN trực tiếp. Địa chỉ SLAAC/temporary của Windows có thể thay đổi sau reboot mà mapping vẫn phải hoạt động vì policy IPv6 nhận diện client theo MAC.

Trên Gateway có thể kiểm tra:

``` bash
ip -6 rule show
sudo ip6tables -t mangle -L -n -v
sudo ip6tables -t nat -L -n -v
sudo ip6tables -L FORWARD -n -v
```

## 5.10 Kiểm tra reboot Gateway

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

# Chương 6 --- Quản lý nhiều VM

Chỉ triển khai thêm sau khi VM101 vượt qua đầy đủ kiểm thử ở Chương 5.

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

# Chương 7 --- Backup, cập nhật và bảo trì

Các dữ liệu quan trọng cần backup gồm:

``` text
/etc/hev/
/etc/dhcp/dhcpd.conf
/etc/default/isc-dhcp-server
/etc/proxy-gateway/network.conf
/etc/radvd.conf
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

# Chương 8 --- Xử lý sự cố

## 8.1 DHCP không start

Kiểm tra:

``` bash
grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server
ip -br a
sudo dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf
sudo journalctl -u isc-dhcp-server -n 50 --no-pager
```

Nếu log báo `No subnet declaration for <WAN>` thì rất có thể
`INTERFACESv4` đang trỏ nhầm WAN.

## 8.2 Add VM báo thiếu Unbound

``` bash
command -v unbound
command -v unbound-checkconf
```

Nếu thiếu:

``` bash
sudo apt install -y unbound
sudo systemctl disable --now unbound 2>/dev/null || true
```

## 8.3 HEV báo không tìm thấy interface cũ

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

## 8.4 VM có Internet qua proxy nhưng DNS lỗi

Trên VM kiểm tra `ipconfig /all`. DNS phải là `10.0.1.1`.

Trên Gateway:

``` bash
systemctl status proxy-gateway-dns@101 --no-pager
sudo ss -lntup | grep 53101
sudo iptables -t nat -L PREROUTING -n -v --line-numbers
```

## 8.5 Thu thập snapshot chẩn đoán

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
sysctl net.ipv6.conf.all.forwarding

echo '=== RADVD ==='
systemctl is-active radvd

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

-   [ ] Installer hoàn tất với `Proxy Gateway installation complete: PASS`.\n-   [ ] Cloud-Init không còn quản lý network.
-   [ ] WAN và LAN được xác định đúng.
-   [ ] LAN giữ `10.0.1.1/24` và `fd10:0:1::1/64`.
-   [ ] `/etc/proxy-gateway/network.conf` khớp phần cứng hiện tại.
-   [ ] IPv4 forwarding = `1` và IPv6 forwarding = `1`.
-   [ ] `radvd` active; client IPv6 Automatic nhận prefix/DNS qua RA.
-   [ ] ISC DHCP Server chạy trên LAN.
-   [ ] DHCP cấp gateway `10.0.1.1` và DNS `10.0.1.1`.
-   [ ] HEV binary đã cài và chạy được.
-   [ ] Unbound đã cài; default `unbound.service` không chạy.
-   [ ] Đủ 7 management script, quyền `750 root:root`.
-   [ ] Đủ 3 systemd unit và đã `daemon-reload`.
-   [ ] Web UI hoạt động.
-   [ ] VM101 nhận đúng IP/MAC reservation.
-   [ ] VM IPv4 resolve DNS qua `10.0.1.1`; VM IPv6 Automatic resolve qua `fd10:0:1::1`.
-   [ ] VM IPv4/IPv6 ra đúng public IP của SOCKS5 tương ứng.
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
