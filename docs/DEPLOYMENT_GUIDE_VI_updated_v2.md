# Proxy Gateway v1.0.2 Deployment Guide

---

## Document Information

Project

Proxy Gateway

Version

v1.0.2

Target Platform

Ubuntu Server 22.04 LTS

Purpose

This document explains how to deploy the complete Proxy Gateway system
from a fresh Ubuntu Server installation.

The intended audience already has:

- Ubuntu Server installed
- SSH access
- Basic Linux administration knowledge

This guide focuses only on deploying Proxy Gateway.

---

# Deployment Workflow


```
Ubuntu Server

↓

Disable Cloud-Init

↓

Configure Network

↓

Enable IPv4 Forwarding

↓

Install DHCP Server

↓

Deploy HEV Runtime

↓

Deploy Proxy Gateway

↓

Deploy Web UI

↓

Verification

↓

Create First VM

↓

Validate Proxy Routing

↓

Deployment Complete
```


---

# Chương 1 - Tắt Cloud-Init

## 1.1 Overview

Ubuntu Server may use Cloud-Init to regenerate network configuration
during boot.

Proxy Gateway manages networking through Netplan.

Cloud-Init network management must therefore be disabled before any
network configuration changes are made.

---

## 1.2 Tắt Cloud-Init Network Configuration

Create the configuration directory if necessary.


```bash
sudo mkdir -p /etc/cloud/cloud.cfg.d
```


Create the configuration file.


```bash
echo "network: {config: disabled}" | \
sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
```


---

## 1.3 Verification

Verify the configuration.


```bash
cat /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
```


Expected output


```yaml
network: {config: disabled}
```


---

## 1.4 Notes

Cloud-Init itself is not removed.

Only its network configuration component is disabled.

Other Cloud-Init functionality remains unaffected.

---

Kết thúc Chương 1

---

# Chương 2 - Cấu hình mạng

## 2.1 Overview

Proxy Gateway uses two independent network interfaces.

One interface connects to the upstream network (WAN).

The second interface provides the private LAN used by client virtual
machines.

The recommended topology is shown below.


```
                Internet
                    │
                    │
            Home Router / Modem
                    │
              DHCP (WAN Address)
                    │
          enp2s0 (WAN Interface)
        ┌──────────────────────────┐
        │      Proxy Gateway       │
        └──────────────────────────┘
          enp3s0 (LAN Interface)
                    │
          10.0.1.1 /24
                    │
          VMware / Proxmox Clients
```


---

## 2.2 Determine Network Interfaces

Identify available interfaces.


```bash
ip link
```


or


```bash
ip addr
```


Example:


```
enp2s0    WAN
enp3s0    LAN
```


Interface names may differ depending on hardware.

Verify the correct interface before continuing.

---

## 2.3 Configure Netplan

Edit the Netplan configuration.


```bash
sudo nano /etc/netplan/00-installer-config.yaml
```


Example configuration:


```yaml
network:
  version: 2
  renderer: networkd

  ethernets:

    enp2s0:
      dhcp4: true

    enp3s0:
      dhcp4: false

      addresses:
        - 10.0.1.1/24
```


---

## 2.4 Apply Configuration

Generate and apply the configuration.


```bash
sudo netplan generate

sudo netplan apply
```


No errors should be reported.

---

## 2.5 Verification

Verify interface addresses.


```bash
ip addr
```


Expected:


```
WAN Interface

DHCP Address
(example)

192.168.x.x

LAN Interface

10.0.1.1/24
```


Verify the routing table.


```bash
ip route
```


Expected:

- Default route via the WAN interface.
- Connected route for 10.0.1.0/24.

---

## 2.6 Connectivity Test

Verify Internet connectivity.


```bash
ping -c 4 8.8.8.8
```


Verify DNS resolution.


```bash
ping -c 4 google.com
```


Both commands should succeed before continuing.

---

## 2.7 Notes

Only the WAN interface should obtain its address using DHCP.

The LAN interface must always use a static address.

Changing the LAN subnet after deployment requires updating:

- DHCP configuration
- Policy routing
- Client gateway settings

Avoid changing the LAN network after deployment.

---

Kết thúc Chương 2

---

# Chương 3 - Bật IPv4 Forwarding

## 3.1 Overview

Proxy Gateway forwards IPv4 traffic from client virtual machines to the
configured SOCKS5 tunnels.

Linux IP forwarding must be enabled before any routing configuration
can function correctly.

---

## 3.2 Verify Current Configuration

Check the current status.


```bash
cat /proc/sys/net/ipv4/ip_forward
```


Expected output after deployment:


```
1
```


If the value is `0`, forwarding is disabled.

---

## 3.3 Bật IPv4 Forwarding

Edit the sysctl configuration.


```bash
sudo nano /etc/sysctl.conf
```


Locate the following parameter.


```
net.ipv4.ip_forward
```


If it exists, change it to:


```
net.ipv4.ip_forward=1
```


If the parameter does not exist, append it to the end of the file.

---

## 3.4 Apply the Configuration

Reload the kernel parameters.


```bash
sudo sysctl -p
```


Output mong đợi:


```
net.ipv4.ip_forward = 1
```


---

## 3.5 Verification

Verify the runtime value.


```bash
cat /proc/sys/net/ipv4/ip_forward
```


Expected:


```
1
```


Verify using sysctl.


```bash
sysctl net.ipv4.ip_forward
```


Expected:


```
net.ipv4.ip_forward = 1
```


---

## 3.6 Notes

IP forwarding is a system-wide kernel setting.

Without this option, Proxy Gateway cannot forward packets between the
LAN interface and the HEV tunnel interfaces.

This setting survives system reboot because it is stored in
`/etc/sysctl.conf`.

---

Kết thúc Chương 3

---

# Chương 4 - Cài đặt và cấu hình ISC DHCP Server

## 4.1 Overview

Proxy Gateway assigns a dedicated LAN IP address to each virtual machine
using ISC DHCP Server.

Each VM receives:

- A fixed IPv4 address
- A fixed default gateway
- A fixed DNS server

All DHCP reservations are managed automatically by Proxy Gateway.

---

## 4.2 Install ISC DHCP Server

Update package information.


```bash
sudo apt update
```


Install the DHCP server.


```bash
sudo apt install isc-dhcp-server -y
```


Verify installation.


```bash
systemctl status isc-dhcp-server
```


The service may report configuration errors until DHCP has been configured.

This is expected.

---

## 4.3 Configure DHCP Interface

Edit the DHCP service configuration.


```bash
sudo nano /etc/default/isc-dhcp-server
```


Locate:


```text
INTERFACESv4=""
```


Replace with:


```text
INTERFACESv4="LAN_INTERFACE"
```


Replace `LAN_INTERFACE` with the actual LAN interface name.

Example:


```text
INTERFACESv4="enp1s0"
```


---

## 4.4 Configure dhcpd.conf

Edit the DHCP configuration.


```bash
sudo nano /etc/dhcp/dhcpd.conf
```


Example configuration.


```text
authoritative;

default-lease-time 600;
max-lease-time 7200;

subnet 10.0.1.0 netmask 255.255.255.0 {

    option routers 10.0.1.1;

    option subnet-mask 255.255.255.0;

    option domain-name-servers
        8.8.8.8,
        1.1.1.1;

    range 10.0.1.100 10.0.1.200;

}
```


The Web UI later appends static host reservations automatically.

---

## 4.5 Validate Configuration

Verify syntax.


```bash
sudo dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf
```


Expected result.


```
Syntax OK
```


No errors should be reported.

---

## 4.6 Start the DHCP Service

Restart the service.


```bash
sudo systemctl restart isc-dhcp-server
```


Enable automatic startup.


```bash
sudo systemctl enable isc-dhcp-server
```


---

## 4.7 Verification

Verify service status.


```bash
systemctl status isc-dhcp-server
```


Expected:


```
Active: active (running)
```


Verify listening interface.


```bash
ss -lunp | grep dhcp
```


The DHCP server should listen only on the LAN interface.

---

## 4.8 Notes

Do not manually edit DHCP reservations after Proxy Gateway has been deployed.

All reservations are managed by:

- Web UI
- set-dhcp-reservation.sh
- remove-hev-instance.sh

Manual edits may conflict with automated management.

---

Kết thúc Chương 4

---

# Chương 5 - Triển khai HEV Runtime

## 5.1 Overview

HEV SOCKS5 Tunnel is the core networking component of Proxy Gateway.

Each virtual machine is assigned an independent HEV tunnel.

Every tunnel has:

- Its own configuration
- Its own routing table
- Its own systemd service
- Its own policy routing rule

This design isolates failures between virtual machines.

If one SOCKS5 proxy becomes unavailable, the remaining tunnels continue
to operate normally.

---

## 5.2 Cài đặt HEV SOCKS5 Tunnel

Proxy Gateway v1.0.3 đã được kiểm thử với HEV SOCKS5 Tunnel 2.14.4.
Trên Ubuntu Server x86_64, nên sử dụng binary release dựng sẵn thay vì
biên dịch HEV từ source.

Kiểm tra kiến trúc hệ thống:


```bash
uname -m
```


Kết quả mong đợi:


```text
x86_64
```


Cài `wget` nếu hệ thống chưa có:


```bash
sudo apt update
sudo apt install -y wget
```


Tải binary HEV SOCKS5 Tunnel 2.14.4 dành cho Linux x86_64:


```bash
cd /tmp

wget -O hev-socks5-tunnel \
    https://github.com/heiher/hev-socks5-tunnel/releases/download/2.14.4/hev-socks5-tunnel-linux-x86_64
```


Kiểm tra file vừa tải:


```bash
ls -lh /tmp/hev-socks5-tunnel
file /tmp/hev-socks5-tunnel
```


Cài binary vào `/usr/local/bin`:


```bash
sudo install -m 755 \
    /tmp/hev-socks5-tunnel \
    /usr/local/bin/hev-socks5-tunnel
```


Kiểm tra cài đặt:


```bash
command -v hev-socks5-tunnel
hev-socks5-tunnel --version
```


Kết quả mong đợi:

- `command -v` trả về `/usr/local/bin/hev-socks5-tunnel`
- HEV hiển thị phiên bản đã cài đặt

Không cần clone hoặc build source HEV khi triển khai theo hướng dẫn này.

---

## 5.3 Runtime Directory Structure

Create the runtime directory.


```bash
sudo mkdir -p /etc/hev
```


The runtime layout is:


```
/etc/hev/

101/

102/

...

120/
```


Each VM owns an independent directory.

---

## 5.4 Instance Configuration

Each instance contains:


```
config.yml

instance.conf
```


config.yml

HEV runtime configuration.

instance.conf

Proxy Gateway metadata.

---

## 5.5 Configuration Generation

Configuration files are not edited manually.

They are generated automatically by:


```
add-hev-instance.sh
```


Later modified by:


```
change-proxy.sh
```


and removed by:


```
remove-hev-instance.sh
```


---

## 5.6 Tunnel Interface

Each VM owns a dedicated tunnel interface.

Example:


```
VM101

↓

hev101
```



```
VM102

↓

hev102
```


No tunnel interface is shared.

---

## 5.7 Routing Tables

Each VM owns an independent routing table.

Example.


```
VM101

↓

hev101

↓

Routing Table

↓

201
```


The routing table number is generated automatically.

---

## 5.8 Policy Routing

Each client IP is associated with its routing table.

Example.


```
10.0.1.101

↓

Routing Table hev101
```



```
10.0.1.102

↓

Routing Table hev102
```


This allows every VM to use a different SOCKS5 proxy.

---

## 5.9 Verification

Verify runtime directory.


```bash
ls /etc/hev
```


Verify tunnel binary.


```bash
which hev-socks5-tunnel
```


Verify version.


```bash
hev-socks5-tunnel --version
```


Expected result.

The binary exists and reports its version correctly.

---

## 5.10 Notes

Proxy Gateway creates tunnel instances dynamically.

Administrators should never manually create or delete directories
inside `/etc/hev`.

Always use the Web UI or the management scripts.

---

Kết thúc Chương 5

---

# Chương 6 - Triển khai các file cấu hình

## 6.1 Overview

Proxy Gateway stores all runtime configuration outside the project
directory.

Configuration files are deployed into the system configuration
directories and remain available after application updates.

The project itself is not used as the runtime location.

---

## 6.2 Configuration Layout

The deployed configuration consists of the following directories.


```
/etc/hev/

/etc/dhcp/

/etc/iproute2/
```


These directories are maintained by Proxy Gateway during normal
operation.

---

## 6.3 HEV Configuration

Each virtual machine receives an independent configuration directory.

Example.


```
/etc/hev/101/

config.yml

instance.conf
```


The files are generated automatically.

Do not copy or edit them manually.

---

## 6.4 DHCP Configuration

Proxy Gateway updates:


```
/etc/dhcp/dhcpd.conf
```


Only the static host reservations are modified.

The subnet definition remains unchanged.

---

## 6.5 Routing Table Configuration

Policy routing requires entries in:


```
/etc/iproute2/rt_tables
```


Proxy Gateway automatically creates and removes routing table
definitions.

Manual editing is not recommended.

---

## 6.6 File Permissions

Configuration files are owned by:


```
root:root
```


Sensitive files containing SOCKS5 credentials are protected with
restricted permissions.

---

## 6.7 Verification

Verify the runtime directories.


```bash
ls /etc/hev

ls /etc/dhcp

ls /etc/iproute2
```


Verify permissions.


```bash
ls -l /etc/hev
```


Configuration files should be readable by root.

---

## 6.8 Notes

The project directory under:


```
~/proxy-gateway-v1.0.1-source
```


contains only the source code.

Runtime configuration always resides under `/etc`.

---

Kết thúc Chương 6

---

# Chương 7 - Triển khai các script quản lý

## 7.1 Overview

Proxy Gateway uses a collection of Bash scripts for VM provisioning,
DHCP reservation management, SOCKS5 proxy updates, routing setup, backup,
rollback, and instance removal.

The source scripts are located under:


```text
<project-root>/scripts/
```


At runtime, they are installed under:


```text
/usr/local/sbin/
```


---

## 7.2 Required Packages

Install the commands used by the management scripts.


```bash
sudo apt update

sudo apt install -y \
    netcat-openbsd \
    iptables \
    python3
```


Verify the required commands:


```bash
command -v nc
command -v iptables
command -v python3
```


Each command must return a valid executable path.

---

## 7.3 Tải source code Proxy Gateway từ GitHub

Các lệnh ở những mục tiếp theo sử dụng các đường dẫn tương đối như
`scripts/`, `systemd/`, `webui/` và `config/`. Vì vậy cần tải source code
Proxy Gateway về Ubuntu trước khi chạy các lệnh triển khai.

Cài Git nếu hệ thống chưa có:


```bash
sudo apt update
sudo apt install -y git
```


Clone repository:


```bash
cd ~
git clone https://github.com/dtthhoanglong/proxy-gateway.git
cd proxy-gateway
```


Để triển khai đúng phiên bản đã kiểm thử v1.0.3, chuyển sang tag `v1.0.3`:


```bash
git fetch --tags origin
git checkout v1.0.3
```


Kiểm tra phiên bản:


```bash
git describe --tags --exact-match
git status
```


Kết quả mong đợi:


```text
v1.0.3
```


Từ mục này trở đi, các lệnh có đường dẫn bắt đầu bằng `scripts/`,
`systemd/`, `webui/` hoặc `config/` phải được chạy từ thư mục gốc của
project:


```text
~/proxy-gateway
```


---

## 7.4 Install the Scripts

From the project root, copy the management scripts:


```bash
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


This command:

- copies the scripts
- assigns ownership to `root:root`
- sets permission mode `750`
- replaces an existing version when upgrading

---

## 7.5 Script Responsibilities

> **Mục này chỉ dùng để tham khảo.**
>
> Không cần chạy các lệnh ví dụ trong mục 7.5 trong quá trình cài đặt.
> Nếu sử dụng Web UI, giao diện Web sẽ tự gọi các management script như
> `add-hev-instance.sh`, `change-proxy.sh` và `set-dhcp-reservation.sh`
> khi người quản trị thực hiện thao tác tương ứng.

### add-hev-instance.sh

Creates a new HEV instance.

Responsibilities include:

- validate VM number
- validate proxy port
- test proxy TCP connectivity
- create `/etc/hev/<instance>`
- generate `config.yml`
- generate `instance.conf`
- add the routing-table definition
- enable and start the instance service
- rollback partially created resources after an error

Usage:


```bash
sudo /usr/local/sbin/add-hev-instance.sh \
    INSTANCE \
    PROXY_IP \
    PROXY_PORT \
    USERNAME \
    PASSWORD
```


Example:


```bash
sudo /usr/local/sbin/add-hev-instance.sh \
    104 \
    203.0.113.10 \
    3904 \
    ExampleUser4 \
    ChangeThisPassword
```


---

### hev-instance-up.sh

Runs after HEV creates the tunnel interface.

Responsibilities include:

- wait for the HEV interface
- create a direct WAN route to the SOCKS5 server
- create the per-VM routing table
- create the source-based policy rule
- create forwarding rules
- create the direct-WAN REJECT rule
- enforce fail-close behavior

This script is normally invoked by systemd.

It should not normally be run manually.

---

### change-proxy.sh

Updates the SOCKS5 proxy assigned to an existing VM.

Responsibilities include:

- validate the instance and proxy port
- test proxy TCP connectivity
- back up `config.yml`
- back up `instance.conf`
- update address, port, username, and password
- restart the HEV service
- restore the previous configuration after an error

Usage:


```bash
sudo /usr/local/sbin/change-proxy.sh \
    INSTANCE \
    PROXY_IP \
    PROXY_PORT \
    USERNAME \
    PASSWORD
```


---

### set-dhcp-reservation.sh

Creates or updates the DHCP reservation for one VM.

Responsibilities include:

- normalize and validate the MAC address
- remove the old reservation for the same VM
- reject duplicate MAC addresses
- reject duplicate fixed IP addresses
- back up `dhcpd.conf`
- validate the new DHCP configuration
- restart ISC DHCP Server
- restore the previous configuration after an error

Usage:


```bash
sudo /usr/local/sbin/set-dhcp-reservation.sh \
    INSTANCE \
    MAC_ADDRESS
```


Example:


```bash
sudo /usr/local/sbin/set-dhcp-reservation.sh \
    104 \
    00:0C:29:4E:24:6F
```


---

### remove-hev-instance.sh

Removes one managed VM from Proxy Gateway.

Responsibilities include:

- back up the HEV instance directory
- remove the DHCP reservation
- validate and restart ISC DHCP Server
- stop and disable the HEV service
- remove the policy-routing rule
- flush the routing table
- remove the HEV tunnel interface
- remove forwarding and fail-close rules
- remove the routing-table definition
- remove `/etc/hev/<instance>`

Usage:


```bash
sudo /usr/local/sbin/remove-hev-instance.sh INSTANCE
```


Example:


```bash
sudo /usr/local/sbin/remove-hev-instance.sh 104
```


This command removes the Proxy Gateway configuration only.

It does not delete the actual VMware, Proxmox, ESXi, or VirtualBox guest.

---

### dns-instance-up.sh

Prepares the per-VM DNS runtime before the corresponding Unbound DNS
instance starts.

Responsibilities include:

- add the dedicated DNS source IP to loopback
- create the per-VM DNS policy-routing rules
- enforce DNS fail-close behavior when the HEV tunnel is unavailable

---

### cleanup-hev-backups.sh

Limits the number of stored backups.

The current defaults retain:

- 10 DHCP configuration backups
- 10 HEV configuration backups per instance
- 5 removed-instance backup directories

The script is called automatically after selected management operations.

---

## 7.6 Validate Script Syntax

Kiểm tra chính xác cả 7 management script đã cài đặt:


```bash
for file in \
    /usr/local/sbin/add-hev-instance.sh \
    /usr/local/sbin/change-proxy.sh \
    /usr/local/sbin/cleanup-hev-backups.sh \
    /usr/local/sbin/hev-instance-up.sh \
    /usr/local/sbin/remove-hev-instance.sh \
    /usr/local/sbin/set-dhcp-reservation.sh \
    /usr/local/sbin/dns-instance-up.sh; do

    echo "Checking $file"

    if [ ! -f "$file" ]; then
        echo "ERROR: Missing $file"
        exit 1
    fi

    sudo bash -n "$file" || exit 1
done
```


Kết quả mong đợi:

- đủ cả 7 file đều được kiểm tra
- không có lỗi syntax
- không xuất hiện dòng `ERROR: Missing ...`

---

## 7.7 Verify Installation

List the installed files:


```bash
sudo ls -l \
    /usr/local/sbin/add-hev-instance.sh \
    /usr/local/sbin/change-proxy.sh \
    /usr/local/sbin/cleanup-hev-backups.sh \
    /usr/local/sbin/hev-instance-up.sh \
    /usr/local/sbin/remove-hev-instance.sh \
    /usr/local/sbin/set-dhcp-reservation.sh \
    /usr/local/sbin/dns-instance-up.sh
```


Expected ownership:


```text
root root
```


Expected executable permissions:


```text
-rwxr-x---
```


---

Kết thúc Chương 7

---

# Chương 8 - Triển khai các systemd service

## 8.1 Overview

Proxy Gateway uses two systemd unit files:


```text
hev-socks5-tunnel@.service
proxy-gateway-ui.service
```


The HEV unit is a template service.

The Web UI unit starts the Flask application through Gunicorn.

---

## 8.2 Install the HEV Template Service

Copy the service file:


```bash
sudo install -o root -g root -m 644 \
    systemd/hev-socks5-tunnel@.service \
    /etc/systemd/system/hev-socks5-tunnel@.service
```


Sau khi cài hoặc thay đổi systemd unit file, yêu cầu systemd đọc lại cấu hình:


```bash
sudo systemctl daemon-reload
```


Kiểm tra unit đã được systemd nhận:


```bash
systemctl cat hev-socks5-tunnel@.service
```


Lệnh trên phải hiển thị nội dung của
`/etc/systemd/system/hev-socks5-tunnel@.service`.

The `%i` placeholder is replaced by the VM number.

Examples:


```text
hev-socks5-tunnel@101.service
hev-socks5-tunnel@102.service
hev-socks5-tunnel@104.service
```


---

## 8.3 HEV Service Lifecycle

For VM104, systemd runs:


```text
/usr/local/bin/hev-socks5-tunnel /etc/hev/104/config.yml
```


After HEV starts, systemd runs:


```text
/usr/local/sbin/hev-instance-up.sh 104
```


The post-start script installs the routes, policy rule, forwarding rules,
and fail-close rule for that VM.

The service automatically restarts after a failure.

---

## 8.4 Install the Web UI Service

Copy the service file:


```bash
sudo install -o root -g root -m 644 \
    systemd/proxy-gateway-ui.service \
    /etc/systemd/system/proxy-gateway-ui.service
```


The service runs:


```text
/usr/bin/gunicorn
```


and binds the Web UI to:


```text
10.0.1.1:8080
```


The application runs as `root` because it must execute system-level
management scripts and control systemd services.

The Web UI must therefore be exposed only to a trusted LAN.

---

## 8.5 Reload systemd


```bash
sudo systemctl daemon-reload
```


Verify the service definitions:


```bash
systemctl cat hev-socks5-tunnel@.service

systemctl cat proxy-gateway-ui.service
```


---

## 8.6 Enable the Web UI

Do not start the Web UI until its application files and Python
dependencies have been installed.

After completing Chapter 9, enable it with:


```bash
sudo systemctl enable --now proxy-gateway-ui
```


---

## 8.7 Managing HEV Instances

Start an instance:


```bash
sudo systemctl start hev-socks5-tunnel@104
```


Stop an instance:


```bash
sudo systemctl stop hev-socks5-tunnel@104
```


Restart an instance:


```bash
sudo systemctl restart hev-socks5-tunnel@104
```


Check status:


```bash
systemctl status hev-socks5-tunnel@104
```


Do not enable an instance before its `/etc/hev/<instance>` configuration
has been created.

The Add VM process enables the service automatically.

---

## 8.8 Verification


```bash
systemctl list-unit-files | grep -E \
'hev-socks5-tunnel|proxy-gateway-ui'
```


Expected entries:


```text
hev-socks5-tunnel@.service
proxy-gateway-ui.service
```


---

Kết thúc Chương 8

---

# Chương 9 - Triển khai Flask Web UI

## 9.1 Overview

The Proxy Gateway Web UI consists of:


```text
app.py

templates/
    add_vm.html
    index.html
    vm.html
```


The runtime application directory is:


```text
/opt/proxy-gateway-ui
```


The Web UI reads:


```text
/etc/dhcp/dhcpd.conf
/etc/hev/
```


and invokes the management scripts installed under:


```text
/usr/local/sbin/
```


---

## 9.2 Install Python Dependencies

Install Flask and Gunicorn:


```bash
sudo apt update

sudo apt install -y \
    python3 \
    python3-flask \
    gunicorn
```


Verify:


```bash
python3 -c "import flask; print(flask.__version__)"

gunicorn --version
```


Both commands must complete successfully.

---

## 9.3 Create the Runtime Directory


```bash
sudo mkdir -p /opt/proxy-gateway-ui/templates
```


---

## 9.4 Install the Application

Copy the Flask backend:


```bash
sudo install -o root -g root -m 644 \
    webui/app.py \
    /opt/proxy-gateway-ui/app.py
```


Copy the templates:


```bash
sudo install -o root -g root -m 644 \
    webui/templates/add_vm.html \
    webui/templates/index.html \
    webui/templates/vm.html \
    /opt/proxy-gateway-ui/templates/
```


---

## 9.5 Validate Python Syntax


```bash
sudo python3 -m py_compile \
    /opt/proxy-gateway-ui/app.py
```


No error should be reported.

---

## 9.6 Verify Script Paths

The application expects these files:


```text
/usr/local/sbin/add-hev-instance.sh
/usr/local/sbin/set-dhcp-reservation.sh
/usr/local/sbin/remove-hev-instance.sh
/usr/local/sbin/change-proxy.sh
```


Verify:


```bash
sudo test -x /usr/local/sbin/add-hev-instance.sh
sudo test -x /usr/local/sbin/set-dhcp-reservation.sh
sudo test -x /usr/local/sbin/remove-hev-instance.sh
sudo test -x /usr/local/sbin/change-proxy.sh

echo "Required Web UI scripts are executable."
```


The final message appears only if all four checks succeed.

---

## 9.7 Start the Web UI


```bash
sudo systemctl daemon-reload

sudo systemctl enable --now proxy-gateway-ui
```


Verify:


```bash
systemctl is-active proxy-gateway-ui
```


Expected:


```text
active
```


---

## 9.8 Open the Web UI

From a client connected to the Proxy Gateway LAN, open:


```text
http://10.0.1.1:8080
```


The Dashboard should load.

---

## 9.9 Health Check

From Ubuntu:


```bash
curl http://10.0.1.1:8080/health
```


Expected response:


```json
{"status":"ok"}
```


---

## 9.10 Service Logs

View recent logs:


```bash
journalctl -u proxy-gateway-ui -n 100 --no-pager
```


Follow logs in real time:


```bash
journalctl -fu proxy-gateway-ui
```


---

## 9.11 Security Warning

Version v1.0.2 does not provide:

- Web UI authentication
- HTTPS
- CSRF protection
- role-based access control

The service also runs as root.

Do not expose port `8080` to the Internet or an untrusted network.

Restrict access to the trusted management LAN.

---

Kết thúc Chương 9

---

# Chương 10 - Kiểm tra toàn bộ quá trình cài đặt

## 10.1 Overview

Before creating the first managed VM, verify that every required
component has been installed and is operating correctly.

This chapter checks:

- network configuration
- IPv4 forwarding
- ISC DHCP Server
- HEV runtime
- management scripts
- systemd services
- Flask Web UI
- required runtime directories

Do not continue to Chapter 11 until all checks pass.

---

## 10.2 Verify Network Interfaces

Display interface addresses:


```bash
ip -br address
```


Kết quả mong đợi:

- WAN interface has a valid upstream address.
- LAN interface has `10.0.1.1/24`.

Example:


```text
wlp2s0    UP    192.168.2.200/24
enp1s0    UP    10.0.1.1/24
```


Interface names may differ on other hardware.

---

## 10.3 Verify the Default Route


```bash
ip route | grep '^default'
```


Kết quả mong đợi:


```text
default via 192.168.2.1 dev wlp2s0
```


The exact WAN interface and gateway may differ.

There must be only one active default route used for upstream Internet
connectivity.

---

## 10.4 Verify LAN Route


```bash
ip route | grep '10.0.1.0/24'
```


Kết quả mong đợi:


```text
10.0.1.0/24 dev enp1s0 proto kernel scope link src 10.0.1.1
```


---

## 10.5 Verify Internet Connectivity

Test IPv4 connectivity:


```bash
ping -c 4 1.1.1.1
```


Test DNS resolution:


```bash
getent hosts github.com
```


Both tests must succeed.

---

## 10.6 Verify IPv4 Forwarding


```bash
sysctl net.ipv4.ip_forward
```


Expected:


```text
net.ipv4.ip_forward = 1
```


---

## 10.7 Verify ISC DHCP Server

Check configuration syntax:


```bash
sudo dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf
```


Kết quả mong đợi:

The command completes without reporting configuration errors.

Check service status:


```bash
systemctl is-active isc-dhcp-server
```


Expected:


```text
active
```


Verify the configured LAN interface:


```bash
grep '^INTERFACESv4=' /etc/default/isc-dhcp-server
```


Expected example:


```text
INTERFACESv4="enp1s0"
```


---

## 10.8 Verify HEV Runtime

Check the binary:


```bash
command -v hev-socks5-tunnel
```


Expected:


```text
/usr/local/bin/hev-socks5-tunnel
```


Check the runtime directory:


```bash
sudo test -d /etc/hev \
    && echo "/etc/hev exists"
```


Expected:


```text
/etc/hev exists
```


At this stage, `/etc/hev` may still be empty.

---

## 10.9 Verify Management Scripts

Run:


```bash
for file in \
    /usr/local/sbin/add-hev-instance.sh \
    /usr/local/sbin/change-proxy.sh \
    /usr/local/sbin/cleanup-hev-backups.sh \
    /usr/local/sbin/hev-instance-up.sh \
    /usr/local/sbin/remove-hev-instance.sh \
    /usr/local/sbin/set-dhcp-reservation.sh; do

    if [ -x "$file" ]; then
        echo "OK: $file"
    else
        echo "MISSING OR NOT EXECUTABLE: $file"
    fi
done
```


All six files must report `OK`.

---

## 10.10 Verify systemd Unit Files


```bash
systemctl cat hev-socks5-tunnel@.service
```



```bash
systemctl cat proxy-gateway-ui.service
```


Both unit files must load successfully.

Check the Web UI service:


```bash
systemctl is-active proxy-gateway-ui
```


Expected:


```text
active
```


---

## 10.11 Verify Web UI Health

From the Ubuntu gateway:


```bash
curl http://10.0.1.1:8080/health
```


Expected response:


```json
{"status":"ok"}
```


From a LAN client, open:


```text
http://10.0.1.1:8080
```


The Dashboard should load without errors.

---

## 10.12 Verify Runtime File Permissions

Check the scripts:


```bash
sudo ls -l /usr/local/sbin/*hev*.sh
```


Check the Web UI:


```bash
sudo ls -l /opt/proxy-gateway-ui
sudo ls -l /opt/proxy-gateway-ui/templates
```


Expected:

- system scripts owned by `root:root`
- management scripts executable
- application files readable by root
- templates present

---

## 10.13 Verify Required Commands


```bash
for command in \
    python3 \
    gunicorn \
    nc \
    iptables \
    dhcpd \
    systemctl; do

    command -v "$command" >/dev/null 2>&1 \
        && echo "OK: $command" \
        || echo "MISSING: $command"
done
```


Every command must report `OK`.

---

## 10.14 Optional Pre-Deployment Snapshot

Before creating the first VM, create a backup of the clean deployment.


```bash
sudo tar -czf \
/root/proxy-gateway-clean-install-backup.tar.gz \
/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg \
/etc/netplan \
/etc/sysctl.conf \
/etc/dhcp \
/etc/hev \
/etc/iproute2 \
/usr/local/sbin \
/etc/systemd/system/hev-socks5-tunnel@.service \
/etc/systemd/system/proxy-gateway-ui.service \
/opt/proxy-gateway-ui
```


Verify:


```bash
sudo ls -lh \
/root/proxy-gateway-clean-install-backup.tar.gz
```


This archive represents the system before any managed VM is created.

---

## 10.15 Verification Checklist

Trước khi tiếp tục, confirm:

- [ ] Cloud-Init network management is disabled.
- [ ] WAN connectivity works.
- [ ] LAN address is `10.0.1.1/24`.
- [ ] IPv4 forwarding is enabled.
- [ ] ISC DHCP Server is active.
- [ ] HEV binary is installed.
- [ ] All six management scripts are executable.
- [ ] Both systemd unit files are installed.
- [ ] Proxy Gateway Web UI is active.
- [ ] `/health` returns `{"status":"ok"}`.
- [ ] Web UI opens from a LAN client.

If any item fails, resolve it before creating the first VM.

---

Kết thúc Chương 10

Proxy Gateway v1.0.2 Deployment Guide

Chapter 11 (Part 1)

------------------------------------------------------------------------

# Chương 11 - Tạo và kiểm thử VM đầu tiên

11.1 Overview

This chapter creates the first managed VM and verifies the complete
traffic path:

Client VM ↓ Proxy Gateway ↓ Source-based policy routing ↓ HEV tunnel ↓
SOCKS5 proxy ↓ Internet

Use one test VM before adding the remaining instances.

Example values used throughout this chapter:

-   VM number: 101
-   Client IP: 10.0.1.101
-   Tunnel: hev101
-   Routing table: hev101
-   Rule priority: 1001

------------------------------------------------------------------------

11.2 Prepare the Client VM

Create or select one virtual machine.

Connect it only to the Proxy Gateway LAN.

Do not attach the VM to another bridged or NAT network that can reach
the Internet directly.

------------------------------------------------------------------------

11.3 Record the VM MAC Address

Record the MAC address of the virtual NIC.

Example:

00:0C:29:AA:BB:CC

------------------------------------------------------------------------

11.4 Open the Add VM Page

Open:

http://10.0.1.1:8080

Select:

Add VM

Fill in:

VM Number : 101 MAC Address : 00:0C:29:AA:BB:CC Proxy IP : Proxy Port :
Username : Password :

------------------------------------------------------------------------

11.5 Create the VM

After clicking Create, Proxy Gateway performs:

1.  Validate the VM number.
2.  Validate the MAC address.
3.  Validate the proxy address.
4.  Test proxy connectivity.
5.  Create /etc/hev/101.
6.  Generate config.yml.
7.  Generate instance.conf.
8.  Register routing table.
9.  Enable and start the HEV service.
10. Create the DHCP reservation.
11. Validate dhcpd.conf.
12. Restart ISC DHCP Server.

Kết thúc Chương 11 - Part 1

Proxy Gateway v1.0.2 Deployment Guide

Chapter 11 (Part 2)

------------------------------------------------------------------------

11.6 Verify the HEV Instance Directory

Run:

    sudo find /etc/hev/101 \
        -maxdepth 1 \
        -type f \
        -printf '%f\n' \
        | sort

Expected:

-   config.yml
-   instance.conf

Review the instance metadata:

    sudo cat /etc/hev/101/instance.conf

Verify values similar to:

-   CLIENT_IP=10.0.1.101
-   TUN_IF=hev101
-   ROUTE_TABLE=hev101
-   TABLE_ID=201
-   RULE_PRIORITY=1001

------------------------------------------------------------------------

11.7 Verify the DHCP Reservation

Display the reservation:

    grep -A4 -B1 'host vm101' /etc/dhcp/dhcpd.conf

Verify that the reservation contains:

-   host vm101
-   hardware ethernet
-   fixed-address 10.0.1.101

Validate the DHCP configuration:

    sudo dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf

The command must complete without reporting syntax errors.

Verify the service:

    systemctl is-active isc-dhcp-server

Expected:

    active

------------------------------------------------------------------------

11.8 Obtain the Reserved Address

Renew the DHCP lease.

Windows:

    ipconfig /release
    ipconfig /renew
    ipconfig /all

Linux:

    sudo dhclient -r
    sudo dhclient
    ip address
    ip route

Verify:

-   Client IP = 10.0.1.101
-   Gateway = 10.0.1.1
-   DNS supplied by the gateway

------------------------------------------------------------------------

11.9 Verify the HEV Service

Check service state:

    systemctl is-active hev-socks5-tunnel@101

Expected:

    active

Detailed status:

    systemctl status hev-socks5-tunnel@101 --no-pager

Recent log entries:

    journalctl -u hev-socks5-tunnel@101 -n 100 --no-pager

Confirm that the service started without errors.

------------------------------------------------------------------------

11.10 Verify the Tunnel Interface

Display the tunnel:

    ip -br address show hev101

Example:

    hev101    UNKNOWN    198.18.0.1/32

The interface state may appear as UNKNOWN. This is normal for a
point-to-point tunnel interface.

Kết thúc Chương 11 - Part 2

Proxy Gateway v1.0.2 Deployment Guide

Chapter 11 (Part 3)

------------------------------------------------------------------------

11.11 Verify the Policy Rule

Display the policy rule assigned to VM101.

    ip rule | grep '10.0.1.101'

Output mong đợi:

    1001: from 10.0.1.101 lookup hev101

Verify that:

-   the source address is 10.0.1.101
-   the routing table is hev101
-   the rule priority matches the generated configuration

------------------------------------------------------------------------

11.12 Verify the Routing Table

Display the routing table:

    ip route show table hev101

Expected:

    default dev hev101 scope link
    10.0.1.0/24 dev LAN_INTERFACE scope link

Replace LAN_INTERFACE with the actual LAN interface name.

Verify the direct route to the SOCKS5 server:

    ip route get <PROXY_IP>

The route must use the WAN interface instead of the HEV tunnel.

------------------------------------------------------------------------

11.13 Verify Forwarding and Fail-Close Rules

Display forwarding rules:

    sudo iptables -S FORWARD | grep '10.0.1.101'

Expected rules include:

-   LAN → HEV ACCEPT
-   HEV → LAN ESTABLISHED,RELATED ACCEPT
-   LAN → WAN REJECT

The REJECT rule prevents the VM from accessing the Internet directly if
the tunnel becomes unavailable.

------------------------------------------------------------------------

11.14 Verify Public IP Through the Proxy

From the client VM:

Windows:

    curl https://ifconfig.me

Linux:

    curl https://ifconfig.me

Kết quả mong đợi:

The returned public IP matches the assigned SOCKS5 proxy.

It must not match the public IP of the gateway WAN connection.

------------------------------------------------------------------------

11.15 Verify DNS Resolution

Windows:

    nslookup github.com

Linux:

    getent hosts github.com

DNS resolution must succeed.

If DNS resolution fails while direct IP connectivity works, review the
DHCP DNS configuration and the gateway DNS service before continuing.

Kết thúc Chương 11 - Part 3

Proxy Gateway v1.0.2 Deployment Guide

Chapter 11 (Part 4)

------------------------------------------------------------------------

11.16 Test Tunnel Restart

Restart the HEV service:

    sudo systemctl restart hev-socks5-tunnel@101

Verify the service state:

    systemctl is-active hev-socks5-tunnel@101

Expected:

    active

From the client VM:

    curl https://ifconfig.me

The returned public IP should remain the SOCKS5 proxy address.

------------------------------------------------------------------------

11.17 Test Fail-Close

Stop the HEV service:

    sudo systemctl stop hev-socks5-tunnel@101

From the client VM:

    curl --max-time 10 https://ifconfig.me

Kết quả mong đợi:

-   connection timeout, or
-   connection failure.

The client VM must not access the Internet through the gateway WAN.

Start the service again:

    sudo systemctl start hev-socks5-tunnel@101

Verify:

    systemctl is-active hev-socks5-tunnel@101

Expected:

    active

Repeat:

    curl https://ifconfig.me

The SOCKS5 proxy public IP should be returned again.

------------------------------------------------------------------------

11.18 Test Web UI Service Controls

Open the VM101 detail page.

Verify the following actions:

-   Start
-   Restart
-   Stop
-   Start again

After each action verify:

    systemctl is-active hev-socks5-tunnel@101

The displayed Web UI status should match the actual systemd service
state.

------------------------------------------------------------------------

11.19 Test Proxy Replacement

Open the VM101 page.

Replace the SOCKS5 server with another working proxy.

Submit the change.

Verify:

    systemctl is-active hev-socks5-tunnel@101

Expected:

    active

From the client VM:

    curl https://ifconfig.me

The public IP should change to the newly assigned SOCKS5 proxy.

------------------------------------------------------------------------

11.20 Reboot Verification

Reboot the gateway:

    sudo reboot

Reconnect using SSH.

Verify:

    systemctl is-active isc-dhcp-server
    systemctl is-active proxy-gateway-ui
    systemctl is-active hev-socks5-tunnel@101

Expected:

    active
    active
    active

Verify runtime state:

    ip -br address show hev101
    ip rule | grep '10.0.1.101'
    ip route show table hev101

From the client VM:

    curl https://ifconfig.me

The VM should automatically regain Internet access through the SOCKS5
proxy after the gateway reboot.

------------------------------------------------------------------------

11.21 Verification Checklist

Confirm the following:

-   VM101 exists in the Web UI.
-   /etc/hev/101/config.yml exists.
-   /etc/hev/101/instance.conf exists.
-   DHCP reservation vm101 exists.
-   Client IP is 10.0.1.101.
-   HEV service is active.
-   Tunnel interface hev101 exists.
-   Policy rule exists.
-   Routing table is correct.
-   Forwarding rules exist.
-   Fail-close rule exists.
-   Public IP matches the SOCKS5 proxy.
-   Tunnel restart succeeds.
-   Fail-close blocks direct WAN access.
-   Proxy replacement succeeds.
-   Configuration survives a gateway reboot.

When all checks pass, the first managed VM has been deployed
successfully and the gateway is ready for additional VM instances.

------------------------------------------------------------------------

Kết thúc Chương 11

Proxy Gateway v1.0.2 Deployment Guide

Chapter 12 (Part 1)

------------------------------------------------------------------------

# Chương 12 - Quản lý nhiều VM instance

12.1 Overview

After the first VM has been tested successfully, Proxy Gateway can be
expanded to manage additional virtual machines.

Version v1.0.2 supports managed instance numbers:

    101 through 120

The design follows a one-VM, one-tunnel, one-routing-table model.

    VM101 -> 10.0.1.101 -> hev101 -> routing table hev101 -> Proxy 101
    VM102 -> 10.0.1.102 -> hev102 -> routing table hev102 -> Proxy 102
    ...
    VM120 -> 10.0.1.120 -> hev120 -> routing table hev120 -> Proxy 120

Each VM is managed independently. A failure of one HEV instance or one
SOCKS5 proxy should not require the other VM tunnels to be stopped or
restarted.

------------------------------------------------------------------------

12.2 Instance Addressing Plan

Proxy Gateway derives the client IP address from the instance number.

    VM101 -> 10.0.1.101
    VM102 -> 10.0.1.102
    VM103 -> 10.0.1.103
    ...
    VM120 -> 10.0.1.120

Each VM must have a unique virtual NIC MAC address.

  VM    Client IP    Tunnel   Routing Table
  ----- ------------ -------- ---------------
  101   10.0.1.101   hev101   hev101
  102   10.0.1.102   hev102   hev102
  103   10.0.1.103   hev103   hev103
  104   10.0.1.104   hev104   hev104
  105   10.0.1.105   hev105   hev105
  106   10.0.1.106   hev106   hev106
  107   10.0.1.107   hev107   hev107
  108   10.0.1.108   hev108   hev108
  109   10.0.1.109   hev109   hev109
  110   10.0.1.110   hev110   hev110
  111   10.0.1.111   hev111   hev111
  112   10.0.1.112   hev112   hev112
  113   10.0.1.113   hev113   hev113
  114   10.0.1.114   hev114   hev114
  115   10.0.1.115   hev115   hev115
  116   10.0.1.116   hev116   hev116
  117   10.0.1.117   hev117   hev117
  118   10.0.1.118   hev118   hev118
  119   10.0.1.119   hev119   hev119
  120   10.0.1.120   hev120   hev120

Do not assign the same MAC address to more than one managed VM.

------------------------------------------------------------------------

12.3 Proxy Allocation

For maximum isolation, assign one SOCKS5 proxy to each VM.

    VM101 -> SOCKS5 Proxy 101
    VM102 -> SOCKS5 Proxy 102
    ...
    VM120 -> SOCKS5 Proxy 120

Before deployment, prepare a private inventory containing:

-   VM number
-   VM MAC address
-   expected client IP
-   SOCKS5 server address
-   SOCKS5 port
-   SOCKS5 username
-   SOCKS5 password

Do not store production proxy passwords in screenshots, public
documentation, Git commits, or public issue reports.

------------------------------------------------------------------------

12.4 Add Additional VM Instances

After VM101 has passed all Chapter 11 tests, additional instances can be
created from the Web UI.

Open:

    http://10.0.1.1:8080

Select Add VM.

For each additional VM:

1.  Select the required instance number.
2.  Enter the VM’s unique MAC address.
3.  Enter the assigned SOCKS5 server address and port.
4.  Enter the SOCKS5 username and password.
5.  Submit the form.
6.  Confirm that the VM appears on the Dashboard.
7.  Confirm that its HEV status is Running.
8.  Renew DHCP on the client.
9.  Verify the expected 10.0.1.x address.
10. Verify the proxy public IP before creating the next instance.

Example for VM102:

    systemctl is-active hev-socks5-tunnel@102
    ip -br address show hev102
    ip rule | grep '10.0.1.102'
    ip route show table hev102
    grep -A4 -B1 'host vm102' /etc/dhcp/dhcpd.conf

From VM102:

    curl https://ifconfig.me

The result must match the SOCKS5 proxy assigned to VM102.

Recommended sequence:

    Create VM
        ↓
    Verify DHCP
        ↓
    Verify HEV service
        ↓
    Verify policy routing
        ↓
    Verify proxy public IP
        ↓
    Create the next VM

Do not create all 20 instances first and test them only at the end.

------------------------------------------------------------------------

Kết thúc Chương 12 - Part 1

Proxy Gateway v1.0.2 Deployment Guide

Chapter 12 (Part 2)

------------------------------------------------------------------------

12.5 Verify Multiple HEV Instances

After adding several VMs, verify that each HEV service is running
independently.

Example for VM101 through VM105:

    for i in 101 102 103 104 105; do
        printf "VM%s: " "$i"
        systemctl is-active "hev-socks5-tunnel@$i"
    done

Expected:

    VM101: active
    VM102: active
    VM103: active
    VM104: active
    VM105: active

To view all currently loaded HEV instance services:

    systemctl list-units \
        'hev-socks5-tunnel@*.service' \
        --all \
        --no-pager

A failed instance should be investigated individually instead of
restarting every HEV service.

------------------------------------------------------------------------

12.6 Verify Multiple Tunnel Interfaces and Policy Rules

Display HEV tunnel interfaces:

    ip -br address | grep '^hev'

Example:

    hev101    UNKNOWN    198.18.0.1/32
    hev102    UNKNOWN    198.18.0.1/32
    hev103    UNKNOWN    198.18.0.1/32

Each HEV process uses its own tunnel interface even though the
tunnel-side address may be identical.

Verify source-based policy rules:

    ip rule

For deployed instances, confirm that each client address has its own
rule.

Example:

    1001: from 10.0.1.101 lookup hev101
    1002: from 10.0.1.102 lookup hev102
    1003: from 10.0.1.103 lookup hev103

Check an individual VM when required:

    ip rule | grep '10.0.1.104'

The source address must point to the routing table belonging to the same
instance.

------------------------------------------------------------------------

12.7 Verify Per-VM Routing Tables

Each managed VM has an independent routing table.

Example:

    ip route show table hev101
    ip route show table hev102
    ip route show table hev103

Each table should contain a default route through its matching HEV
interface.

Conceptually:

    10.0.1.101
        ↓
    policy rule
        ↓
    table hev101
        ↓
    hev101
        ↓
    SOCKS5 Proxy 101

    10.0.1.102
        ↓
    policy rule
        ↓
    table hev102
        ↓
    hev102
        ↓
    SOCKS5 Proxy 102

Do not configure one VM to use another VM’s routing table.

To inspect the registered HEV routing-table entries:

    grep -E '[[:space:]]hev(10[1-9]|11[0-9]|120)$' \
        /etc/iproute2/rt_tables

------------------------------------------------------------------------

12.8 Verify Proxy Separation

Test the public IP from every deployed client VM.

For example, from VM101:

    curl https://ifconfig.me

From VM102:

    curl https://ifconfig.me

From VM103:

    curl https://ifconfig.me

Record the result for each VM and compare it with the proxy inventory.

Example:

    VM101 -> Proxy public IP A
    VM102 -> Proxy public IP B
    VM103 -> Proxy public IP C

When different SOCKS5 proxies are assigned, each VM should return the
public IP of its own proxy.

A VM returning the gateway WAN public IP indicates a routing or
fail-close problem and must be investigated before deployment continues.

------------------------------------------------------------------------

12.9 Failure Isolation Test

Failure isolation is a core design property of the multi-instance
architecture.

The objective is:

    Proxy 104 fails
           ↓
    VM104 loses Internet access

    VM101 remains online
    VM102 remains online
    VM103 remains online
    VM105 remains online

To perform a controlled test, stop one instance:

    sudo systemctl stop hev-socks5-tunnel@104

From VM104:

    curl --max-time 10 https://ifconfig.me

Expected:

-   connection timeout, or
-   connection failure,
-   and no direct WAN public IP.

Now test another VM, for example VM103:

    curl https://ifconfig.me

VM103 should continue to use its assigned SOCKS5 proxy normally.

Also verify VM105 if available:

    curl https://ifconfig.me

VM105 should remain unaffected.

Restore VM104:

    sudo systemctl start hev-socks5-tunnel@104

Verify:

    systemctl is-active hev-socks5-tunnel@104

Expected:

    active

Then test VM104 again:

    curl https://ifconfig.me

Its assigned proxy public IP should return.

------------------------------------------------------------------------

12.10 Verify Fail-Close for Each Instance

Each VM must have a direct-WAN REJECT rule.

Example for VM104:

    sudo iptables -S FORWARD | grep '10.0.1.104'

Confirm that the rule set includes:

-   LAN to hev104 forwarding
-   return traffic from hev104
-   direct LAN-to-WAN REJECT for 10.0.1.104

Repeat for other instances as required.

The intended behavior is:

    HEV available
        ↓
    VM traffic uses its assigned proxy

    HEV unavailable
        ↓
    Direct WAN path rejected
        ↓
    VM has no Internet access

Fail-close must be verified before the VM is considered
production-ready.

------------------------------------------------------------------------

Kết thúc Chương 12 - Part 2

Proxy Gateway v1.0.2 Deployment Guide

Chapter 12 (Part 3)

------------------------------------------------------------------------

12.11 Operating Multiple VM Instances

After all required instances have been deployed, normal operation should
be performed on one VM at a time whenever possible.

Use the Web UI for routine operations such as:

-   checking VM status
-   starting an HEV instance
-   stopping an HEV instance
-   restarting an HEV instance
-   changing the assigned SOCKS5 proxy
-   deleting a managed VM

Avoid restarting all HEV instances to resolve a problem affecting only
one VM.

For command-line verification, an individual service can be checked
with:

    systemctl status hev-socks5-tunnel@104 --no-pager

Recent logs:

    journalctl -u hev-socks5-tunnel@104 -n 100 --no-pager

Restart only that instance when required:

    sudo systemctl restart hev-socks5-tunnel@104

------------------------------------------------------------------------

12.12 Changing a Proxy in a Multi-VM Deployment

Changing the proxy for one VM must not require changes to other VM
instances.

From the Web UI:

1.  Open the required VM detail page.
2.  Enter the replacement SOCKS5 proxy information.
3.  Submit the change.
4.  Confirm that the HEV service returns to Running.
5.  Test the public IP from that VM.
6.  Confirm that another VM remains unaffected.

Example for VM104:

    systemctl is-active hev-socks5-tunnel@104

Then from VM104:

    curl https://ifconfig.me

The returned address should match the replacement proxy.

Check another VM separately to confirm isolation.

Do not manually edit /etc/hev/<instance>/config.yml during normal
operation when the Web UI or management script can perform the change.

------------------------------------------------------------------------

12.13 Removing a VM from a Multi-VM Deployment

When an instance is no longer required, use the Delete VM action in the
Web UI.

Deletion removes the Proxy Gateway configuration associated with that
instance, including its HEV configuration, service state, routing state,
and DHCP reservation.

It does not delete the actual virtual machine from VMware, Proxmox,
ESXi, or VirtualBox.

After deleting VM104, verify:

    test ! -d /etc/hev/104 \
        && echo "HEV directory removed"

Check the DHCP reservation:

    grep 'host vm104' /etc/dhcp/dhcpd.conf

No VM104 reservation should be returned.

Check the policy rule:

    ip rule | grep '10.0.1.104'

No VM104 policy rule should remain.

Check the routing table registration:

    grep -E '[[:space:]]hev104$' /etc/iproute2/rt_tables

No hev104 entry should remain.

Verify that unrelated instances are still active:

    systemctl is-active hev-socks5-tunnel@103
    systemctl is-active hev-socks5-tunnel@105

------------------------------------------------------------------------

12.14 Reusing a Deleted Instance Number

A deleted instance number can be used again after its previous
configuration has been removed successfully.

For example:

    Delete VM104
        ↓
    Verify cleanup
        ↓
    Add VM104 again
        ↓
    Assign MAC address
        ↓
    Assign SOCKS5 proxy
        ↓
    Verify DHCP and routing
        ↓
    Test public IP

The new VM104 deployment may use a different MAC address and a different
SOCKS5 proxy.

After recreating it, repeat the relevant verification steps from Chapter
11.

------------------------------------------------------------------------

12.15 Capacity Model

Version v1.0.2 supports instance numbers 101 through 120.

A fully populated deployment therefore contains up to:

    20 managed VM instances
    20 client IP addresses
    20 DHCP reservations
    20 HEV tunnel instances
    20 source-based policy rules
    20 per-VM routing tables
    up to 20 independently assigned SOCKS5 proxies

The logical design is:

    VM101 -> hev101 -> Proxy 101
    VM102 -> hev102 -> Proxy 102
    VM103 -> hev103 -> Proxy 103
    ...
    VM120 -> hev120 -> Proxy 120

Actual performance depends on the gateway hardware, WAN connection,
SOCKS5 proxy quality, traffic pattern, and workload of the client VMs.

Do not assume that the existence of 20 supported instance numbers
guarantees identical throughput under every workload.

------------------------------------------------------------------------

12.16 Recommended Deployment Practice

For a new installation, scale gradually.

Recommended sequence:

    VM101
        ↓
    Full verification

    VM102
        ↓
    Full verification

    VM103
        ↓
    Full verification

    Continue until the required number of VMs is reached

After several instances are active, perform a failure-isolation test.

Before production use:

-   verify every VM MAC address
-   verify every DHCP reservation
-   verify every HEV service
-   verify every policy rule
-   verify every routing table
-   verify every proxy public IP
-   verify fail-close behavior
-   verify recovery after a gateway reboot

------------------------------------------------------------------------

12.17 Multi-VM Best Practices

Follow these rules during normal operation:

1.  Use a unique MAC address for every VM.
2.  Keep the standard VM101 through VM120 addressing scheme.
3.  Assign each VM its intended SOCKS5 proxy.
4.  Use the Web UI for routine instance management.
5.  Avoid manual edits to generated HEV configuration.
6.  Troubleshoot one failed instance before changing healthy instances.
7.  Verify the public IP after every proxy change.
8.  Verify fail-close after major routing or firewall changes.
9.  Keep proxy credentials out of public documentation and Git.
10. Back up the gateway before major upgrades or bulk configuration
    changes.

------------------------------------------------------------------------

12.18 Final Multi-VM Verification Checklist

For every deployed VM, confirm:

-   ☐ VM number is between 101 and 120.
-   ☐ VM has a unique MAC address.
-   ☐ VM receives the expected 10.0.1.x address.
-   ☐ DHCP reservation exists.
-   ☐ /etc/hev/<instance>/config.yml exists.
-   ☐ /etc/hev/<instance>/instance.conf exists.
-   ☐ HEV systemd service is active.
-   ☐ Matching HEV tunnel interface exists.
-   ☐ Matching source policy rule exists.
-   ☐ Matching routing table exists.
-   ☐ Forwarding rules exist.
-   ☐ Direct-WAN fail-close rule exists.
-   ☐ Public IP matches the assigned SOCKS5 proxy.
-   ☐ Failure of this instance does not interrupt other VMs.

Gateway-wide checks:

-   ☐ ISC DHCP Server is active.
-   ☐ Proxy Gateway Web UI is active.
-   ☐ WAN connectivity is available.
-   ☐ LAN gateway remains 10.0.1.1.
-   ☐ All required instances recover after a gateway reboot.
-   ☐ No deleted instance leaves stale DHCP, routing, or HEV state.

When these checks pass, the multi-VM Proxy Gateway deployment is ready
for normal operation.

------------------------------------------------------------------------

Kết thúc Chương 12

Proxy Gateway v1.0.2 Deployment Guide

Chapter 13 (Part 1)

------------------------------------------------------------------------

# Chương 13 - Backup và Restore

13.1 Overview

A Proxy Gateway backup should preserve both the project-independent
system configuration and the runtime configuration created for managed
VM instances.

Important data includes:

-   HEV instance configuration
-   DHCP configuration and reservations
-   policy-routing table definitions
-   systemd unit files
-   management scripts
-   Web UI application
-   network configuration
-   forwarding configuration

Proxy credentials are stored in HEV configuration files. Backups must
therefore be treated as sensitive data.

Do not upload production backups to public repositories or public file
sharing services.

------------------------------------------------------------------------

13.2 Create a Backup Directory

Create a protected backup directory:

    sudo mkdir -p /root/proxy-gateway-backups
    sudo chmod 700 /root/proxy-gateway-backups

Verify:

    sudo ls -ld /root/proxy-gateway-backups

Expected permissions should restrict access to root.

------------------------------------------------------------------------

13.3 Back Up HEV Instance Configuration

Back up all current HEV instances:

    sudo tar -czf \
    /root/proxy-gateway-backups/hev-$(date +%Y%m%d-%H%M%S).tar.gz \
    /etc/hev

List available HEV backups:

    sudo ls -lh /root/proxy-gateway-backups/hev-*.tar.gz

This archive may contain SOCKS5 usernames and passwords.

Protect it accordingly.

------------------------------------------------------------------------

13.4 Back Up DHCP Configuration

Create a backup:

    sudo cp -a \
    /etc/dhcp/dhcpd.conf \
    /root/proxy-gateway-backups/dhcpd.conf.$(date +%Y%m%d-%H%M%S)

Also preserve the ISC DHCP interface configuration:

    sudo cp -a \
    /etc/default/isc-dhcp-server \
    /root/proxy-gateway-backups/isc-dhcp-server.$(date +%Y%m%d-%H%M%S)

Validate the live DHCP configuration before considering the backup
complete:

    sudo dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf

------------------------------------------------------------------------

13.5 Back Up Routing Table Definitions

Back up:

    sudo cp -a \
    /etc/iproute2/rt_tables \
    /root/proxy-gateway-backups/rt_tables.$(date +%Y%m%d-%H%M%S)

The file contains the persistent table-name registrations used by the
per-VM HEV instances.

Runtime ip rule, ip route, and iptables state does not need to be copied
as ordinary files. It is recreated by the instance startup logic.

------------------------------------------------------------------------

13.6 Back Up Management Scripts

Create an archive:

    sudo tar -czf \
    /root/proxy-gateway-backups/management-scripts-$(date +%Y%m%d-%H%M%S).tar.gz \
    /usr/local/sbin/add-hev-instance.sh \
    /usr/local/sbin/change-proxy.sh \
    /usr/local/sbin/cleanup-hev-backups.sh \
    /usr/local/sbin/hev-instance-up.sh \
    /usr/local/sbin/remove-hev-instance.sh \
    /usr/local/sbin/set-dhcp-reservation.sh

These scripts should normally be recoverable from the matching source
release, but including them in a system backup records exactly what was
installed at the time of backup.

------------------------------------------------------------------------

13.7 Back Up systemd Units and Web UI

Back up the systemd units:

    sudo tar -czf \
    /root/proxy-gateway-backups/systemd-$(date +%Y%m%d-%H%M%S).tar.gz \
    /etc/systemd/system/hev-socks5-tunnel@.service \
    /etc/systemd/system/proxy-gateway-ui.service

Back up the Web UI:

    sudo tar -czf \
    /root/proxy-gateway-backups/webui-$(date +%Y%m%d-%H%M%S).tar.gz \
    /opt/proxy-gateway-ui

------------------------------------------------------------------------

13.8 Back Up Network and Forwarding Configuration

Back up Netplan configuration:

    sudo tar -czf \
    /root/proxy-gateway-backups/netplan-$(date +%Y%m%d-%H%M%S).tar.gz \
    /etc/netplan

If the deployment uses the documented Cloud-Init network-disable file,
back it up:

    sudo cp -a \
    /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg \
    /root/proxy-gateway-backups/99-disable-network-config.cfg.$(date +%Y%m%d-%H%M%S)

Back up the forwarding configuration used by the deployment:

    sudo cp -a \
    /etc/sysctl.conf \
    /root/proxy-gateway-backups/sysctl.conf.$(date +%Y%m%d-%H%M%S)

------------------------------------------------------------------------

13.9 Create a Complete Configuration Backup

For routine administration, a single archive is more convenient.

Create a timestamped full configuration backup:

    STAMP=$(date +%Y%m%d-%H%M%S)

    sudo tar -czf \
    "/root/proxy-gateway-backups/proxy-gateway-config-$STAMP.tar.gz" \
    /etc/hev \
    /etc/dhcp \
    /etc/default/isc-dhcp-server \
    /etc/iproute2/rt_tables \
    /etc/netplan \
    /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg \
    /etc/sysctl.conf \
    /usr/local/sbin/add-hev-instance.sh \
    /usr/local/sbin/change-proxy.sh \
    /usr/local/sbin/cleanup-hev-backups.sh \
    /usr/local/sbin/hev-instance-up.sh \
    /usr/local/sbin/remove-hev-instance.sh \
    /usr/local/sbin/set-dhcp-reservation.sh \
    /etc/systemd/system/hev-socks5-tunnel@.service \
    /etc/systemd/system/proxy-gateway-ui.service \
    /opt/proxy-gateway-ui

Verify the archive:

    sudo tar -tzf \
    "/root/proxy-gateway-backups/proxy-gateway-config-$STAMP.tar.gz" \
    | head -50

Check its size:

    sudo ls -lh \
    "/root/proxy-gateway-backups/proxy-gateway-config-$STAMP.tar.gz"

Store a copy of important backups on another trusted storage device.

A backup kept only on the Proxy Gateway SSD does not protect against SSD
failure.

------------------------------------------------------------------------

Kết thúc Chương 13 - Part 1

Proxy Gateway v1.0.2 Deployment Guide

Chapter 13 (Part 2)

------------------------------------------------------------------------

13.10 Restore Planning

Do not restore configuration files blindly onto an unknown or
incompatible system.

Before restoration, confirm:

-   the target system is the intended Proxy Gateway
-   Ubuntu and required packages are installed
-   HEV SOCKS5 Tunnel is installed at the expected path
-   WAN and LAN interface names are known
-   the backup belongs to the intended Proxy Gateway version
-   the backup archive is readable
-   current configuration has been backed up if it may still be needed

List the backup archive before extracting it:

    sudo tar -tzf \
    /root/proxy-gateway-backups/proxy-gateway-config-YYYYMMDD-HHMMSS.tar.gz \
    | less

Replace the example timestamp with the actual backup filename.

------------------------------------------------------------------------

13.11 Create a Safety Backup Before Restore

Before overwriting the current configuration, preserve its existing
state.

    STAMP=$(date +%Y%m%d-%H%M%S)

    sudo mkdir -p /root/proxy-gateway-before-restore

    sudo tar -czf \
    "/root/proxy-gateway-before-restore/current-config-$STAMP.tar.gz" \
    /etc/hev \
    /etc/dhcp \
    /etc/default/isc-dhcp-server \
    /etc/iproute2/rt_tables \
    /etc/netplan \
    /etc/sysctl.conf \
    /usr/local/sbin \
    /etc/systemd/system/hev-socks5-tunnel@.service \
    /etc/systemd/system/proxy-gateway-ui.service \
    /opt/proxy-gateway-ui

If a listed file does not exist on the target system, adjust the command
before running it.

------------------------------------------------------------------------

13.12 Stop Proxy Gateway Services Before Restore

Stop the Web UI first:

    sudo systemctl stop proxy-gateway-ui

List HEV instance services:

    systemctl list-units \
        'hev-socks5-tunnel@*.service' \
        --all \
        --no-pager

Stop active HEV instances individually.

Example:

    sudo systemctl stop hev-socks5-tunnel@101
    sudo systemctl stop hev-socks5-tunnel@102

Stopping the services prevents runtime processes from modifying or using
configuration while files are being restored.

------------------------------------------------------------------------

13.13 Restore a Complete Configuration Archive

The complete backup created earlier stores files using their paths
relative to /.

Restore from the root filesystem:

    cd /

Then extract the selected archive:

    sudo tar -xzf \
    /root/proxy-gateway-backups/proxy-gateway-config-YYYYMMDD-HHMMSS.tar.gz

After extraction, reload systemd:

    sudo systemctl daemon-reload

Do not reboot yet.

Validate the restored configuration first.

------------------------------------------------------------------------

13.14 Validate Restored DHCP Configuration

Run:

    sudo dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf

If this reports an error, do not start normal client operation until the
DHCP configuration has been corrected.

Verify the configured DHCP interface:

    grep '^INTERFACESv4=' /etc/default/isc-dhcp-server

Then restart DHCP:

    sudo systemctl restart isc-dhcp-server

Verify:

    systemctl is-active isc-dhcp-server

Expected:

    active

------------------------------------------------------------------------

13.15 Validate Restored Management Scripts

Check that the required scripts exist and are executable:

    for file in \
        /usr/local/sbin/add-hev-instance.sh \
        /usr/local/sbin/change-proxy.sh \
        /usr/local/sbin/cleanup-hev-backups.sh \
        /usr/local/sbin/hev-instance-up.sh \
        /usr/local/sbin/remove-hev-instance.sh \
        /usr/local/sbin/set-dhcp-reservation.sh; do

        if [ -x "$file" ]; then
            echo "OK: $file"
        else
            echo "MISSING OR NOT EXECUTABLE: $file"
        fi
    done

Validate shell syntax:

    for file in \
        /usr/local/sbin/add-hev-instance.sh \
        /usr/local/sbin/change-proxy.sh \
        /usr/local/sbin/cleanup-hev-backups.sh \
        /usr/local/sbin/hev-instance-up.sh \
        /usr/local/sbin/remove-hev-instance.sh \
        /usr/local/sbin/set-dhcp-reservation.sh; do

        sudo bash -n "$file" || exit 1
    done

------------------------------------------------------------------------

13.16 Validate Restored HEV Instances

List restored instances:

    sudo find /etc/hev \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -printf '%f\n' \
        | sort -n

For an example instance:

    sudo test -f /etc/hev/101/config.yml \
        && echo "VM101 config.yml present"

    sudo test -f /etc/hev/101/instance.conf \
        && echo "VM101 instance.conf present"

Review the metadata:

    sudo cat /etc/hev/101/instance.conf

Confirm that WAN and LAN interface names still match the target
hardware.

This is especially important when restoring to a different machine.

------------------------------------------------------------------------

13.17 Restore on Different Hardware

A configuration backup may contain interface names from the original
gateway.

For example:

    Original gateway:
    WAN = wlp2s0
    LAN = enp1s0

A replacement machine may use:

    WAN = enp2s0
    LAN = enp3s0

Do not start all HEV instances until interface-dependent configuration
has been reviewed.

Check:

    ip -br link

Review Netplan:

    sudo ls -l /etc/netplan
    sudo cat /etc/netplan/*.yaml

Review each HEV instance metadata file as required:

    sudo grep -R \
        -E 'WAN_IF|LAN_IF' \
        /etc/hev/*/instance.conf

If interface names differ, update the restored configuration according
to the deployment design before starting the affected services.

------------------------------------------------------------------------

13.18 Start and Verify the Web UI

Start the Web UI:

    sudo systemctl start proxy-gateway-ui

Verify:

    systemctl is-active proxy-gateway-ui

Expected:

    active

Test the health endpoint:

    curl http://10.0.1.1:8080/health

Expected:

    {"status":"ok"}

Open the Dashboard from a trusted LAN client and confirm that the
expected VM instances are displayed.

------------------------------------------------------------------------

13.19 Start and Verify HEV Instances

Start one restored instance first.

Example:

    sudo systemctl start hev-socks5-tunnel@101

Verify:

    systemctl is-active hev-socks5-tunnel@101
    ip -br address show hev101
    ip rule | grep '10.0.1.101'
    ip route show table hev101

From VM101, verify the public IP:

    curl https://ifconfig.me

If VM101 works correctly, continue with the remaining restored instances
one at a time.

This staged restore makes interface, routing, proxy, and credential
problems easier to identify.

------------------------------------------------------------------------

13.20 Reboot Verification After Restore

After configuration and services have been validated, reboot:

    sudo reboot

After reconnecting, verify:

    systemctl is-active isc-dhcp-server
    systemctl is-active proxy-gateway-ui

Check the required HEV services:

    systemctl list-units \
        'hev-socks5-tunnel@*.service' \
        --all \
        --no-pager

Verify a sample instance:

    ip -br address show hev101
    ip rule | grep '10.0.1.101'
    ip route show table hev101

Finally, test the corresponding client VM through its assigned proxy.

------------------------------------------------------------------------

13.21 Backup và Restore Checklist

Before backup:

-   ☐ DHCP configuration validates successfully.
-   ☐ Required HEV instance files exist.
-   ☐ Backup directory is protected.
-   ☐ Backup destination has enough free space.

After backup:

-   ☐ Backup archive exists.
-   ☐ Archive can be listed with tar -tzf.
-   ☐ Sensitive backup is stored securely.
-   ☐ Important backup has a copy outside the gateway SSD.

Before restore:

-   ☐ Correct backup archive has been selected.
-   ☐ Current configuration has been preserved.
-   ☐ Web UI and affected HEV services are stopped.
-   ☐ Target interface names are known.

After restore:

-   ☐ DHCP configuration validates.
-   ☐ ISC DHCP Server is active.
-   ☐ Management scripts are executable.
-   ☐ HEV instance configuration is present.
-   ☐ Web UI is active.
-   ☐ Restored VM appears on the Dashboard.
-   ☐ Policy routing is recreated.
-   ☐ Fail-close remains effective.
-   ☐ Client public IP matches its assigned proxy.
-   ☐ Configuration survives reboot.

------------------------------------------------------------------------

Kết thúc Chương 13

Proxy Gateway v1.0.2 Deployment Guide

Chapter 14 (Part 1)

------------------------------------------------------------------------

# Chương 14 - Bảo trì và nâng cấp

14.1 Overview

Routine maintenance keeps Proxy Gateway stable while preserving the
independent VM-to-proxy mappings.

Maintenance tasks include:

-   checking service health
-   reviewing logs
-   checking disk usage
-   cleaning old backups
-   updating Ubuntu packages
-   updating Proxy Gateway source files
-   validating configuration after changes

Changes should be performed in a controlled manner.

Before a major upgrade, create a backup as described in Chapter 13.

------------------------------------------------------------------------

14.2 Routine Health Check

Check the core services:

    systemctl is-active isc-dhcp-server
    systemctl is-active proxy-gateway-ui

List HEV instance services:

    systemctl list-units \
        'hev-socks5-tunnel@*.service' \
        --all \
        --no-pager

Check network state:

    ip -br address
    ip route
    ip rule

Check Web UI health:

    curl http://10.0.1.1:8080/health

Expected:

    {"status":"ok"}

------------------------------------------------------------------------

14.3 Review Service Logs

Web UI logs:

    journalctl -u proxy-gateway-ui \
        -n 100 \
        --no-pager

Individual HEV instance:

    journalctl -u hev-socks5-tunnel@101 \
        -n 100 \
        --no-pager

ISC DHCP Server:

    journalctl -u isc-dhcp-server \
        -n 100 \
        --no-pager

To follow an HEV service in real time:

    journalctl -fu hev-socks5-tunnel@101

Investigate repeated restart loops, proxy connection failures, DHCP
errors, and routing setup errors before making unrelated changes.

------------------------------------------------------------------------

14.4 Check Disk Usage

Display filesystem usage:

    df -h

Check the largest directories under /var:

    sudo du -xh /var \
        --max-depth=1 \
        2>/dev/null \
        | sort -h

Check Proxy Gateway backups:

    sudo du -sh \
        /root/proxy-gateway-backups \
        2>/dev/null

Check HEV configuration size:

    sudo du -sh /etc/hev

Do not allow the root filesystem to become completely full.

------------------------------------------------------------------------

14.5 Clean Old Proxy Gateway Backups

The project includes:

    /usr/local/sbin/cleanup-hev-backups.sh

Run it manually when required:

    sudo /usr/local/sbin/cleanup-hev-backups.sh

The script manages the backup retention used by Proxy Gateway management
operations.

Do not delete the only known-good external backup during cleanup.

System-level backups created manually in Chapter 13 should be managed
according to the administrator’s own retention policy.

------------------------------------------------------------------------

14.6 Check Configuration Before Maintenance

Validate DHCP:

    sudo dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf

Validate management scripts:

    for file in \
        /usr/local/sbin/add-hev-instance.sh \
        /usr/local/sbin/change-proxy.sh \
        /usr/local/sbin/cleanup-hev-backups.sh \
        /usr/local/sbin/hev-instance-up.sh \
        /usr/local/sbin/remove-hev-instance.sh \
        /usr/local/sbin/set-dhcp-reservation.sh; do

        sudo bash -n "$file" || exit 1
    done

Validate the Web UI Python file:

    sudo python3 -m py_compile \
        /opt/proxy-gateway-ui/app.py

A clean validation result provides a useful baseline before an upgrade.

------------------------------------------------------------------------

14.7 Update Ubuntu Packages

Refresh package metadata:

    sudo apt update

Review available upgrades:

    apt list --upgradable

Install normal updates:

    sudo apt upgrade

Do not perform an unattended distribution release upgrade on a
production Proxy Gateway without a backup and a recovery plan.

After package updates, check whether a reboot is required:

    test -f /var/run/reboot-required \
        && cat /var/run/reboot-required

If a reboot is required, perform the verification steps from Chapter 11
and Chapter 12 after the system returns.

------------------------------------------------------------------------

14.8 Prepare for a Proxy Gateway Application Upgrade

Before replacing Proxy Gateway application files:

1.  Create a full configuration backup.
2.  Record the currently deployed source version.
3.  Verify the current services are healthy.
4.  Review the new release notes or CHANGELOG.
5.  Review changes to scripts, systemd units, configuration templates,
    and Web UI files.

From the source repository:

    cd /home/ubuntu/proxy-gateway-v1.0.1-source

Check repository state:

    git status

Check recent commits:

    git log --oneline --decorate -10

Check available tags:

    git tag --list

Do not overwrite uncommitted local changes without reviewing them first.

------------------------------------------------------------------------

14.9 Back Up Before Upgrading

Follow Chapter 13 to create a full configuration backup.

At minimum, preserve:

    /etc/hev
    /etc/dhcp
    /etc/iproute2/rt_tables
    /usr/local/sbin
    /etc/systemd/system/hev-socks5-tunnel@.service
    /etc/systemd/system/proxy-gateway-ui.service
    /opt/proxy-gateway-ui

Also preserve any local network configuration that differs from the
release defaults.

Verify that the backup archive can be listed before continuing.

------------------------------------------------------------------------

Kết thúc Chương 14 - Part 1

Proxy Gateway v1.0.2 Deployment Guide

Chapter 14 (Part 2)

------------------------------------------------------------------------

14.10 Update the Source Repository

From the source directory:

    cd /home/ubuntu/proxy-gateway-v1.0.1-source

Verify that the working tree is clean:

    git status

Fetch the latest repository information:

    git fetch --tags origin

Review available tags:

    git tag --list --sort=-version:refname

When upgrading to a specific tested release, prefer an explicit release
tag rather than an unknown development commit.

Before switching versions, review:

    git log --oneline --decorate --all -20

and:

    cat CHANGELOG.md

Do not continue if important local modifications have not been backed up
or committed.

------------------------------------------------------------------------

14.11 Validate the New Source Before Deployment

Before copying files into system runtime locations, validate the new
source.

Check Python syntax:

    python3 -m py_compile webui/app.py

Check shell scripts:

    for file in scripts/*.sh; do
        echo "Checking $file"
        bash -n "$file" || exit 1
    done

Review systemd unit files:

    for file in systemd/*.service; do
        echo
        echo "===== $file ====="
        cat "$file"
    done

Review source changes compared with the currently deployed version when
possible:

    git diff <OLD_TAG>..<NEW_TAG> -- \
        scripts \
        systemd \
        webui \
        config

Replace <OLD_TAG> and <NEW_TAG> with the actual release tags.

------------------------------------------------------------------------

14.12 Deploy Updated Management Scripts

Install the updated scripts:

    sudo install -o root -g root -m 750 \
        scripts/add-hev-instance.sh \
        scripts/change-proxy.sh \
        scripts/cleanup-hev-backups.sh \
        scripts/hev-instance-up.sh \
        scripts/remove-hev-instance.sh \
        scripts/set-dhcp-reservation.sh \
        /usr/local/sbin/

Validate the installed copies:

    for file in \
        /usr/local/sbin/add-hev-instance.sh \
        /usr/local/sbin/change-proxy.sh \
        /usr/local/sbin/cleanup-hev-backups.sh \
        /usr/local/sbin/hev-instance-up.sh \
        /usr/local/sbin/remove-hev-instance.sh \
        /usr/local/sbin/set-dhcp-reservation.sh; do

        sudo bash -n "$file" || exit 1
    done

Do not automatically overwrite runtime configuration under /etc/hev
unless the release documentation explicitly requires a configuration
migration.

------------------------------------------------------------------------

14.13 Deploy Updated systemd Units

Install the updated units:

    sudo install -o root -g root -m 644 \
        systemd/hev-socks5-tunnel@.service \
        /etc/systemd/system/hev-socks5-tunnel@.service

    sudo install -o root -g root -m 644 \
        systemd/proxy-gateway-ui.service \
        /etc/systemd/system/proxy-gateway-ui.service

Reload systemd:

    sudo systemctl daemon-reload

Verify:

    systemctl cat hev-socks5-tunnel@.service
    systemctl cat proxy-gateway-ui.service

If the HEV service definition or hev-instance-up.sh changed, test one
instance before restarting every managed VM.

------------------------------------------------------------------------

14.14 Deploy the Updated Web UI

Stop the Web UI:

    sudo systemctl stop proxy-gateway-ui

Install the backend:

    sudo install -o root -g root -m 644 \
        webui/app.py \
        /opt/proxy-gateway-ui/app.py

Install the templates:

    sudo install -o root -g root -m 644 \
        webui/templates/add_vm.html \
        webui/templates/index.html \
        webui/templates/vm.html \
        /opt/proxy-gateway-ui/templates/

Validate:

    sudo python3 -m py_compile \
        /opt/proxy-gateway-ui/app.py

Start the service:

    sudo systemctl start proxy-gateway-ui

Verify:

    systemctl is-active proxy-gateway-ui
    curl http://10.0.1.1:8080/health

Expected:

    active

and:

    {"status":"ok"}

------------------------------------------------------------------------

14.15 Test One HEV Instance After Upgrade

Choose one known-good VM for the first runtime test.

Example:

    sudo systemctl restart hev-socks5-tunnel@101

Verify:

    systemctl is-active hev-socks5-tunnel@101
    ip -br address show hev101
    ip rule | grep '10.0.1.101'
    ip route show table hev101

From VM101:

    curl https://ifconfig.me

Confirm that the public IP still matches the assigned SOCKS5 proxy.

Perform the fail-close test if the upgrade changed:

-   HEV runtime
-   hev-instance-up.sh
-   systemd HEV unit
-   routing logic
-   firewall logic

Only continue with the remaining instances after the test VM passes.

------------------------------------------------------------------------

14.16 Restart Additional Instances When Required

Not every application update requires every HEV service to restart.

If runtime routing or HEV startup logic changed, restart instances one
at a time:

    sudo systemctl restart hev-socks5-tunnel@102
    sudo systemctl restart hev-socks5-tunnel@103

Verify each instance before continuing.

For larger deployments, use a controlled loop only after individual
testing has succeeded:

    for i in $(seq 101 120); do
        if systemctl list-unit-files \
            "hev-socks5-tunnel@$i.service" \
            --no-legend 2>/dev/null \
            | grep -q .; then

            echo "Restarting VM$i"
            sudo systemctl restart "hev-socks5-tunnel@$i" || break
            systemctl is-active "hev-socks5-tunnel@$i" || break
        fi
    done

Manual one-by-one verification remains safer when only a small number of
instances are deployed.

------------------------------------------------------------------------

14.17 Post-Upgrade Verification

Verify core services:

    systemctl is-active isc-dhcp-server
    systemctl is-active proxy-gateway-ui

Verify the Web UI:

    curl http://10.0.1.1:8080/health

List HEV services:

    systemctl list-units \
        'hev-socks5-tunnel@*.service' \
        --all \
        --no-pager

Validate DHCP:

    sudo dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf

Review policy rules:

    ip rule

Review HEV interfaces:

    ip -br address | grep '^hev'

Test several client VMs and confirm that each still returns its assigned
proxy public IP.

------------------------------------------------------------------------

14.18 Roll Back an Application Upgrade

If the new application release causes problems, restore the previous
known-good files from the backup created before the upgrade.

Stop affected services first:

    sudo systemctl stop proxy-gateway-ui

Stop only affected HEV instances if necessary.

Restore:

-   management scripts
-   systemd units
-   Web UI
-   configuration files only if the upgrade modified them

After restoring systemd files:

    sudo systemctl daemon-reload

Start the Web UI:

    sudo systemctl start proxy-gateway-ui

Start and verify one HEV instance:

    sudo systemctl start hev-socks5-tunnel@101
    systemctl is-active hev-socks5-tunnel@101

Then repeat the Chapter 11 verification tests.

Do not delete the failed release or its logs until the cause has been
understood.

------------------------------------------------------------------------

14.19 Reboot After Major Maintenance

After a major update involving system packages, network configuration,
systemd units, or HEV runtime, perform a controlled reboot:

    sudo reboot

After reconnecting, verify:

    systemctl is-active isc-dhcp-server
    systemctl is-active proxy-gateway-ui

Check HEV services:

    systemctl list-units \
        'hev-socks5-tunnel@*.service' \
        --all \
        --no-pager

Verify a sample client:

    ip rule | grep '10.0.1.101'
    ip route show table hev101

Then verify the public IP from VM101.

------------------------------------------------------------------------

14.20 Maintenance and Upgrade Checklist

Before maintenance:

-   ☐ Current system is healthy.
-   ☐ DHCP configuration validates.
-   ☐ Important logs have been reviewed.
-   ☐ Full configuration backup exists.
-   ☐ Backup archive is readable.
-   ☐ Current source version is known.
-   ☐ New release changes have been reviewed.

During upgrade:

-   ☐ New shell scripts pass bash -n.
-   ☐ New Web UI passes Python compilation.
-   ☐ Updated systemd units are reviewed.
-   ☐ Runtime configuration is not overwritten unnecessarily.
-   ☐ Web UI health check passes.
-   ☐ One HEV instance is tested first.

After upgrade:

-   ☐ ISC DHCP Server is active.
-   ☐ Proxy Gateway Web UI is active.
-   ☐ Required HEV instances are active.
-   ☐ HEV interfaces exist.
-   ☐ Policy rules are correct.
-   ☐ Routing tables are correct.
-   ☐ Client public IPs match assigned proxies.
-   ☐ Fail-close works when relevant.
-   ☐ System survives a controlled reboot.

------------------------------------------------------------------------

Kết thúc Chương 14

Proxy Gateway v1.0.2 Deployment Guide

Chapter 15 (Part 1)

------------------------------------------------------------------------

# Chương 15 - Xử lý sự cố

15.1 Overview

Troubleshoot Proxy Gateway from the bottom of the network path upward.

Recommended order:

    Physical link
        ↓
    WAN and LAN interfaces
        ↓
    Client DHCP
        ↓
    Gateway reachability
        ↓
    DNS
        ↓
    HEV service
        ↓
    HEV tunnel interface
        ↓
    Policy rule
        ↓
    Routing table
        ↓
    iptables forwarding and fail-close
        ↓
    SOCKS5 proxy
        ↓
    Public Internet

Avoid changing several components at the same time. Verify one layer,
identify the first failing layer, and repair that layer before
continuing.

------------------------------------------------------------------------

15.2 Collect Basic Diagnostic Information

On the Proxy Gateway, begin with:

    ip -br address
    ip route
    ip rule

Check forwarding:

    sysctl net.ipv4.ip_forward

Expected:

    net.ipv4.ip_forward = 1

Check core services:

    systemctl is-active isc-dhcp-server
    systemctl is-active proxy-gateway-ui

List HEV services:

    systemctl list-units \
        'hev-socks5-tunnel@*.service' \
        --all \
        --no-pager

Check HEV interfaces:

    ip -br address | grep '^hev'

These commands provide a quick overview before configuration is changed.

------------------------------------------------------------------------

15.3 Client Does Not Receive an IP Address

Expected example for VM101:

    IP address: 10.0.1.101
    Gateway:    10.0.1.1

First verify the LAN interface:

    ip -br address

Confirm that the gateway LAN interface has:

    10.0.1.1/24

Check DHCP:

    systemctl status isc-dhcp-server --no-pager

Validate configuration:

    sudo dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf

Check the configured DHCP interface:

    grep '^INTERFACESv4=' /etc/default/isc-dhcp-server

Check the VM reservation:

    grep -A4 -B1 'host vm101' /etc/dhcp/dhcpd.conf

Confirm that the MAC address matches the VM’s actual virtual NIC.

Then renew DHCP on the client.

Windows:

    ipconfig /release
    ipconfig /renew
    ipconfig /all

Linux:

    sudo dhclient -r
    sudo dhclient

------------------------------------------------------------------------

15.4 Client Receives the Wrong IP Address

If VM101 does not receive 10.0.1.101, check:

-   the VM MAC address
-   duplicate MAC addresses
-   duplicate DHCP reservations
-   another DHCP server on the same LAN
-   an additional virtual NIC connected to another network

Search reservations:

    grep -n \
        -E 'host vm|hardware ethernet|fixed-address' \
        /etc/dhcp/dhcpd.conf

A managed VM should use the MAC address registered for its own instance.

------------------------------------------------------------------------

15.5 Client Cannot Reach 10.0.1.1

From the client:

    ping 10.0.1.1

If this fails, troubleshoot the local LAN before investigating the
proxy.

On the gateway:

    ip -br link
    ip -br address

Verify that the LAN interface is UP and owns 10.0.1.1/24.

Check the VM’s virtual network attachment.

The VM must be connected to the network that reaches the Proxy Gateway
LAN.

Do not troubleshoot HEV or SOCKS5 until basic client-to-gateway
connectivity works.

------------------------------------------------------------------------

15.6 Web UI Is Not Reachable

Check:

    systemctl status proxy-gateway-ui --no-pager

Check recent logs:

    journalctl -u proxy-gateway-ui \
        -n 100 \
        --no-pager

Test locally on the gateway:

    curl http://10.0.1.1:8080/health

Expected:

    {"status":"ok"}

Check whether the service is listening:

    sudo ss -lntp | grep ':8080'

The deployed service is expected to bind to:

    10.0.1.1:8080

If the gateway no longer owns 10.0.1.1, fix the LAN network
configuration before changing the Web UI service.

------------------------------------------------------------------------

15.7 Add VM Operation Fails

If the Web UI cannot create a VM, first read the error shown by the UI.

Then inspect:

    journalctl -u proxy-gateway-ui \
        -n 150 \
        --no-pager

Verify the management script:

    sudo test -x /usr/local/sbin/add-hev-instance.sh \
        && echo "add-hev-instance.sh executable"

Validate it:

    sudo bash -n /usr/local/sbin/add-hev-instance.sh

Check that the requested instance is within the supported range:

    101 through 120

Also check:

-   duplicate instance number
-   invalid MAC address
-   invalid proxy port
-   unreachable SOCKS5 server
-   existing stale /etc/hev/<instance> directory
-   DHCP configuration errors

Do not manually create partial instance files until the original failure
has been identified.

------------------------------------------------------------------------

15.8 HEV Service Does Not Start

Example:

    systemctl status hev-socks5-tunnel@101 --no-pager

Read logs:

    journalctl -u hev-socks5-tunnel@101 \
        -n 150 \
        --no-pager

Check the configuration files:

    sudo ls -l /etc/hev/101
    sudo cat /etc/hev/101/instance.conf

Confirm the HEV binary exists:

    command -v hev-socks5-tunnel

The systemd unit expects:

    /usr/local/bin/hev-socks5-tunnel

Verify:

    sudo test -x /usr/local/bin/hev-socks5-tunnel \
        && echo "HEV binary executable"

Check the systemd unit:

    systemctl cat hev-socks5-tunnel@.service

The service should use the instance configuration:

    /etc/hev/%i/config.yml

and execute the post-start routing script.

------------------------------------------------------------------------

15.9 HEV Service Is Active but Tunnel Interface Is Missing

Check:

    ip -br address show hev101

If the interface does not exist, inspect:

    journalctl -u hev-socks5-tunnel@101 \
        -n 150 \
        --no-pager

Review:

    sudo cat /etc/hev/101/config.yml
    sudo cat /etc/hev/101/instance.conf

Confirm that the configured tunnel name corresponds to the expected
instance.

Restart only the affected service:

    sudo systemctl restart hev-socks5-tunnel@101

Then check again:

    ip -br address show hev101

------------------------------------------------------------------------

15.10 Tunnel Exists but VM Has No Internet

Verify the complete runtime path.

Check the policy rule:

    ip rule | grep '10.0.1.101'

Check the routing table:

    ip route show table hev101

Check forwarding rules:

    sudo iptables -S FORWARD | grep '10.0.1.101'

Check HEV logs:

    journalctl -u hev-socks5-tunnel@101 \
        -n 100 \
        --no-pager

Check the proxy server route from the gateway:

    ip route get <PROXY_IP>

The proxy server itself must be reachable through the WAN path rather
than recursively through the HEV tunnel.

------------------------------------------------------------------------

Kết thúc Chương 15 - Part 1

Proxy Gateway v1.0.2 Deployment Guide

Chapter 15 (Part 2)

------------------------------------------------------------------------

15.11 DNS Resolution Fails

A client may have network connectivity but still fail to resolve domain
names.

Typical symptoms include:

    Could not resolve host
    DNS request timed out
    Server failed

First verify the client network configuration.

Windows:

    ipconfig /all

Linux:

    ip address
    ip route
    cat /etc/resolv.conf

Confirm that the client received the DNS configuration intended by the
Proxy Gateway deployment.

Test name resolution from the client.

Windows:

    nslookup github.com

Linux:

    getent hosts github.com

If name resolution fails, verify the DHCP DNS options:

    grep -n \
        -E 'domain-name-servers|option routers' \
        /etc/dhcp/dhcpd.conf

Validate DHCP:

    sudo dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf

If the deployment uses a local DNS service on the gateway, verify that
it is running and listening on the expected address and port.

Do not assume that a DNS failure is an HEV tunnel failure. Test IP
connectivity and DNS separately.

------------------------------------------------------------------------

15.12 SOCKS5 Proxy Is Unreachable

If one VM suddenly loses Internet access while other VMs remain healthy,
the assigned SOCKS5 proxy may be unavailable.

Check the affected HEV service:

    systemctl status hev-socks5-tunnel@104 --no-pager

Review logs:

    journalctl -u hev-socks5-tunnel@104 \
        -n 150 \
        --no-pager

Review the instance metadata and HEV configuration:

    sudo cat /etc/hev/104/instance.conf
    sudo cat /etc/hev/104/config.yml

Verify the route to the proxy server:

    ip route get <PROXY_IP>

If appropriate, test whether the proxy TCP port is reachable from the
gateway:

    nc -vz <PROXY_IP> <PROXY_PORT>

A successful TCP connection does not guarantee that authentication or
SOCKS5 forwarding is working, but a failed TCP connection is useful
evidence of a reachability problem.

If the proxy is confirmed unavailable, replace it through the VM detail
page in the Web UI.

------------------------------------------------------------------------

15.13 VM Returns the Gateway WAN Public IP

This is a critical condition.

A managed VM is expected to use its assigned SOCKS5 proxy.

If the client returns the gateway’s direct WAN public IP, stop normal
use of that VM until routing and fail-close behavior have been verified.

Check:

    ip rule | grep '10.0.1.101'

Expected conceptually:

    from 10.0.1.101 lookup hev101

Check:

    ip route show table hev101

The table must direct the VM traffic through hev101.

Check firewall rules:

    sudo iptables -S FORWARD | grep '10.0.1.101'

Confirm that a direct LAN-to-WAN REJECT rule exists for the VM.

Then repeat the fail-close test:

    sudo systemctl stop hev-socks5-tunnel@101

From VM101:

    curl --max-time 10 https://ifconfig.me

The VM must lose Internet access rather than fall back to the WAN.

Restore the service:

    sudo systemctl start hev-socks5-tunnel@101

------------------------------------------------------------------------

15.14 Public IP Belongs to the Wrong Proxy

If VM102 returns the public IP assigned to another VM, verify the entire
instance mapping.

Check the DHCP reservation:

    grep -A4 -B1 'host vm102' /etc/dhcp/dhcpd.conf

Check the client address:

    Expected: 10.0.1.102

Check the policy rule:

    ip rule | grep '10.0.1.102'

Check the routing table:

    ip route show table hev102

Review:

    sudo cat /etc/hev/102/instance.conf
    sudo cat /etc/hev/102/config.yml

Also verify that the Web UI shows the intended proxy for VM102.

Possible causes include:

-   wrong MAC reservation
-   wrong proxy entered during VM creation
-   wrong proxy entered during a proxy change
-   stale or manually edited instance configuration
-   incorrect policy rule or routing table

Correct only the affected instance and retest.

------------------------------------------------------------------------

15.15 Fail-Close Does Not Work

Fail-close means:

    HEV/proxy available
        ↓
    VM has Internet through SOCKS5

    HEV/proxy unavailable
        ↓
    VM has no Internet

If the VM continues to access the Internet after its HEV service is
stopped, investigate immediately.

Stop the affected service:

    sudo systemctl stop hev-socks5-tunnel@101

Check the VM-specific firewall rules:

    sudo iptables -S FORWARD | grep '10.0.1.101'

Check the client for another active network adapter.

A VM with an additional NAT, bridged, Wi-Fi, or other Internet-capable
adapter may bypass the Proxy Gateway completely.

Also verify that the client default gateway is the Proxy Gateway LAN
address.

Do not consider the VM production-ready until the direct Internet path
has been eliminated.

------------------------------------------------------------------------

15.16 One VM Fails but Other VMs Work

This is the expected isolation boundary of the architecture.

Do not restart the entire gateway first.

For the affected instance, check:

    systemctl status hev-socks5-tunnel@104 --no-pager
    ip -br address show hev104
    ip rule | grep '10.0.1.104'
    ip route show table hev104
    sudo iptables -S FORWARD | grep '10.0.1.104'

Review logs:

    journalctl -u hev-socks5-tunnel@104 \
        -n 150 \
        --no-pager

Then compare with one known-good instance:

    systemctl is-active hev-socks5-tunnel@103
    ip rule | grep '10.0.1.103'
    ip route show table hev103

This comparison often reveals whether the problem is specific to the
proxy, HEV configuration, routing state, or client VM.

------------------------------------------------------------------------

15.17 HEV Instance Fails After Gateway Reboot

Check whether the service is enabled:

    systemctl is-enabled hev-socks5-tunnel@101

Check status:

    systemctl status hev-socks5-tunnel@101 --no-pager

Review current-boot logs:

    journalctl -b \
        -u hev-socks5-tunnel@101 \
        --no-pager

Verify WAN and LAN interfaces:

    ip -br address
    ip route

Check whether the interface names still match:

    sudo cat /etc/hev/101/instance.conf

If the HEV service starts before required network connectivity is
usable, the logs will help identify the startup failure.

After correcting the underlying problem:

    sudo systemctl restart hev-socks5-tunnel@101

Then verify the tunnel, rule, route, and client public IP.

------------------------------------------------------------------------

15.18 Web UI Works but Service Actions Fail

The Dashboard may load normally even if one of the privileged management
scripts is missing or invalid.

Check the Web UI logs:

    journalctl -u proxy-gateway-ui \
        -n 150 \
        --no-pager

Verify required scripts:

    ls -l \
    /usr/local/sbin/add-hev-instance.sh \
    /usr/local/sbin/change-proxy.sh \
    /usr/local/sbin/remove-hev-instance.sh \
    /usr/local/sbin/set-dhcp-reservation.sh

Check shell syntax:

    for file in \
        /usr/local/sbin/add-hev-instance.sh \
        /usr/local/sbin/change-proxy.sh \
        /usr/local/sbin/remove-hev-instance.sh \
        /usr/local/sbin/set-dhcp-reservation.sh; do

        sudo bash -n "$file" || exit 1
    done

Also verify that the Web UI service is running with the deployment’s
expected privileges:

    systemctl cat proxy-gateway-ui.service

------------------------------------------------------------------------

15.19 Delete VM Operation Leaves Stale State

After deleting an instance, verify that its persistent and runtime state
has been removed.

Example for VM104:

    test ! -d /etc/hev/104 \
        && echo "HEV directory removed"

Check DHCP:

    grep 'host vm104' /etc/dhcp/dhcpd.conf

Check policy rule:

    ip rule | grep '10.0.1.104'

Check routing table registration:

    grep -E '[[:space:]]hev104$' /etc/iproute2/rt_tables

Check service state:

    systemctl status hev-socks5-tunnel@104 --no-pager

If stale state remains, inspect:

    journalctl -u proxy-gateway-ui \
        -n 150 \
        --no-pager

and review the removal script before manually deleting additional state.

------------------------------------------------------------------------

15.20 DHCP Service Fails After Adding or Deleting a VM

Validate the configuration:

    sudo dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf

Check status:

    systemctl status isc-dhcp-server --no-pager

Read logs:

    journalctl -u isc-dhcp-server \
        -n 150 \
        --no-pager

Look for:

-   duplicate host blocks
-   duplicate fixed addresses
-   malformed MAC addresses
-   missing braces
-   invalid DHCP syntax

Do not repeatedly restart DHCP while the syntax check is failing.

Repair the configuration first, rerun:

    sudo dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf

and restart only after validation succeeds.

------------------------------------------------------------------------

Kết thúc Chương 15 - Part 2

Proxy Gateway v1.0.2 Deployment Guide

Chapter 15 (Part 3)

------------------------------------------------------------------------

15.21 Routing Rule Is Missing

If the HEV service is active but the expected source policy rule is
missing, check the instance startup state.

Example for VM101:

    ip rule | grep '10.0.1.101'

If no result is returned, inspect:

    sudo cat /etc/hev/101/instance.conf

Check the post-start script:

    sudo bash -n /usr/local/sbin/hev-instance-up.sh

Review service logs:

    journalctl -u hev-socks5-tunnel@101 \
        -n 150 \
        --no-pager

Restart only the affected instance:

    sudo systemctl restart hev-socks5-tunnel@101

Then verify:

    ip rule | grep '10.0.1.101'
    ip route show table hev101

Do not add temporary manual rules and then forget them. The persistent
startup logic should recreate the correct runtime state.

------------------------------------------------------------------------

15.22 Routing Table Is Missing or Incorrect

Check:

    ip route show table hev101

If the table name is unknown, inspect:

    grep -E '[[:space:]]hev101$' /etc/iproute2/rt_tables

Review the instance metadata:

    sudo cat /etc/hev/101/instance.conf

Check that:

-   the routing-table name matches the instance
-   the table ID is valid
-   the tunnel interface matches the instance
-   the client IP matches the instance

Restart the affected service after correcting persistent configuration:

    sudo systemctl restart hev-socks5-tunnel@101

Verify again:

    ip rule | grep '10.0.1.101'
    ip route show table hev101

------------------------------------------------------------------------

15.23 Proxy Server Route Is Incorrect

The SOCKS5 server itself must be reachable through the normal WAN path.

Check:

    ip route get <PROXY_IP>

The result should identify the expected WAN interface and upstream
gateway.

If the proxy server route points into the HEV tunnel, the tunnel may
attempt to reach its own proxy recursively.

Review the instance startup logic and WAN interface configuration before
adding manual routes.

------------------------------------------------------------------------

15.24 WAN Connectivity Is Lost

Check interfaces:

    ip -br address

Check the default route:

    ip route

Test the upstream gateway if appropriate:

    ping -c 4 <WAN_GATEWAY>

Test an Internet IP from the gateway:

    ping -c 4 1.1.1.1

If the gateway itself cannot reach the Internet, do not troubleshoot the
individual SOCKS5 tunnels first.

Repair WAN connectivity before continuing.

------------------------------------------------------------------------

15.25 Gateway Works but Performance Is Poor

Performance problems may originate from:

-   WAN quality
-   SOCKS5 proxy latency
-   SOCKS5 proxy bandwidth
-   packet loss
-   CPU load
-   memory pressure
-   storage or logging pressure
-   client workload

Check system load:

    uptime

Check memory:

    free -h

Check processes:

    top

Check interface statistics:

    ip -s link

Check individual HEV logs for repeated reconnects or errors.

Compare more than one proxy before assuming that the Proxy Gateway
itself is the bottleneck.

------------------------------------------------------------------------

15.26 Disk Space Is Low

Check:

    df -h

Check large directories:

    sudo du -xh /var \
        --max-depth=1 \
        2>/dev/null \
        | sort -h

Check backup storage:

    sudo du -sh \
        /root/proxy-gateway-backups \
        2>/dev/null

Review system journal usage:

    journalctl --disk-usage

Do not delete configuration or unknown system files simply to recover
space.

Remove only understood and unnecessary backups, caches, or logs.

------------------------------------------------------------------------

15.27 Source Files and Runtime Files Are Different

The source repository and installed runtime files are separate.

Example source paths:

    scripts/
    systemd/
    webui/
    config/

Example installed runtime paths:

    /usr/local/sbin/
    /etc/systemd/system/
    /opt/proxy-gateway-ui/
    /etc/hev/
    /etc/dhcp/

Changing a file inside the Git repository does not automatically change
the installed runtime copy.

When troubleshooting an unexpected behavior, compare the source and
runtime versions.

Example:

    diff \
    scripts/hev-instance-up.sh \
    /usr/local/sbin/hev-instance-up.sh

For the Web UI:

    diff \
    webui/app.py \
    /opt/proxy-gateway-ui/app.py

This distinction is especially important after manual upgrades.

------------------------------------------------------------------------

15.28 Full Diagnostic Sequence for One VM

When the cause is unclear, use this sequence.

Example for VM101:

    ip -br address

    systemctl is-active isc-dhcp-server

    grep -A4 -B1 'host vm101' /etc/dhcp/dhcpd.conf

    systemctl status hev-socks5-tunnel@101 --no-pager

    ip -br address show hev101

    ip rule | grep '10.0.1.101'

    ip route show table hev101

    sudo iptables -S FORWARD | grep '10.0.1.101'

    sudo cat /etc/hev/101/instance.conf

    journalctl -u hev-socks5-tunnel@101 \
        -n 150 \
        --no-pager

Then test from VM101:

    curl https://ifconfig.me

If DNS is suspected, test DNS separately.

This sequence should identify the first broken layer without modifying
healthy instances.

------------------------------------------------------------------------

15.29 Full Gateway Diagnostic Snapshot

When requesting support or comparing system state, collect a diagnostic
snapshot without publishing proxy credentials.

Run:

    echo "===== DATE ====="
    date

    echo "===== ADDRESSES ====="
    ip -br address

    echo "===== ROUTES ====="
    ip route

    echo "===== RULES ====="
    ip rule

    echo "===== FORWARDING ====="
    sysctl net.ipv4.ip_forward

    echo "===== DHCP ====="
    systemctl is-active isc-dhcp-server

    echo "===== WEB UI ====="
    systemctl is-active proxy-gateway-ui

    echo "===== HEV SERVICES ====="
    systemctl list-units \
        'hev-socks5-tunnel@*.service' \
        --all \
        --no-pager

    echo "===== HEV INTERFACES ====="
    ip -br address | grep '^hev' || true

    echo "===== DISK ====="
    df -h

    echo "===== MEMORY ====="
    free -h

Do not include /etc/hev/*/config.yml in a public diagnostic report
unless credentials have been removed.

------------------------------------------------------------------------

15.30 When to Restore Instead of Repair

Consider restoring a known-good backup when:

-   multiple configuration files were accidentally overwritten
-   several runtime scripts were replaced with unknown versions
-   a failed upgrade changed many components
-   routing and DHCP state can no longer be confidently reconstructed
-   the previous configuration was known to work correctly

Follow Chapter 13.

A restore should still be followed by validation. A backup is not proof
that the restored environment matches different replacement hardware.

------------------------------------------------------------------------

15.31 Final Xử lý sự cố Checklist

For the affected VM:

-   ☐ VM has the expected MAC address.
-   ☐ VM receives the expected 10.0.1.x address.
-   ☐ Default gateway is correct.
-   ☐ VM can reach 10.0.1.1.
-   ☐ DHCP reservation is correct.
-   ☐ HEV service is active.
-   ☐ HEV tunnel interface exists.
-   ☐ Source policy rule exists.
-   ☐ Per-VM routing table is correct.
-   ☐ Forwarding rules are present.
-   ☐ Direct-WAN fail-close rule is present.
-   ☐ SOCKS5 server is reachable through WAN.
-   ☐ DNS works when required.
-   ☐ Public IP matches the assigned proxy.
-   ☐ Stopping HEV removes Internet access.
-   ☐ Other VM instances remain unaffected.

For the gateway:

-   ☐ WAN interface is up.
-   ☐ LAN interface owns 10.0.1.1/24.
-   ☐ IPv4 forwarding is enabled.
-   ☐ ISC DHCP Server is active.
-   ☐ Web UI is active.
-   ☐ Disk space is sufficient.
-   ☐ System memory is sufficient.
-   ☐ Installed scripts match the intended release.
-   ☐ Configuration survives reboot.

------------------------------------------------------------------------

15.32 Xử lý sự cố Principle

The most important troubleshooting rule is to isolate the failing layer.

Do not begin by reinstalling the gateway.

Do not restart every VM tunnel because one proxy failed.

Do not disable fail-close to make a connectivity test appear successful.

Use the architecture itself to narrow the problem:

    VM
     ↓
    DHCP
     ↓
    LAN
     ↓
    Policy Rule
     ↓
    Routing Table
     ↓
    HEV Tunnel
     ↓
    SOCKS5 Proxy
     ↓
    WAN
     ↓
    Internet

Repair the first layer that fails, verify it, and then continue upward.

------------------------------------------------------------------------

Kết thúc Chương 15
