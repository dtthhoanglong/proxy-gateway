# Proxy Gateway Installation Guide

Version: **v1.0.3**

---

# Table of Contents

1. Introduction
2. Project Overview
3. Hardware Requirements
4. Software Requirements
5. Network Architecture
6. Ubuntu Installation
7. Network Configuration
8. DHCP Server Configuration
9. HEV SOCKS5 Tunnel
10. Web UI
11. Creating a Virtual Machine
12. Managing a Virtual Machine
13. Backup and Restore
14. Troubleshooting
15. Appendix

---

# Chapter 1 - Introduction

## 1.1 Purpose

Proxy Gateway is a lightweight Ubuntu Server based gateway designed to route multiple virtual machines through independent SOCKS5 proxies.

Instead of configuring a proxy inside every guest operating system, each virtual machine simply uses the Ubuntu gateway as its default gateway.

The gateway performs all routing transparently.

Every VM owns:

- its own HEV SOCKS5 tunnel
- its own routing table
- its own policy routing rule
- its own DHCP reservation

Because each VM has an independent tunnel, a proxy failure affects only that VM.

Other virtual machines continue operating normally.

---

## 1.2 Design Goals

The project was designed with the following goals.

- Lightweight
- Easy deployment
- Easy maintenance
- Low hardware requirements
- No additional software inside guest operating systems
- Automatic configuration
- Fail-close routing
- Simple Web management

---

## 1.3 Target Environment

Proxy Gateway is intended for environments running multiple virtual machines.

Typical examples include:

- VMware Workstation
- Proxmox VE
- ESXi
- VirtualBox

The guest operating system can be:

- Windows
- macOS
- Linux

The gateway works independently of the guest operating system.

---

## 1.4 Key Features

Current version provides:

- Add VM
- Delete VM
- Change SOCKS5 Proxy
- DHCP Reservation
- HEV Tunnel Management
- Start / Stop / Restart Tunnel
- Automatic Rollback
- Automatic Backup
- Web UI Management

---

# Chapter 2 - Project Overview

## 2.1 Overall Architecture

```
                Internet
                    │
                    │
            192.168.2.1
                    │
              WiFi / Ethernet
                    │
        Ubuntu Proxy Gateway
         WAN : wlp2s0
         LAN : enp1s0
           10.0.1.1
                    │
────────────────────────────────────
      Virtual Machines
────────────────────────────────────

VM101
10.0.1.101
↓

HEV101
↓

SOCKS5 Proxy #1


VM102
10.0.1.102
↓

HEV102
↓

SOCKS5 Proxy #2


...

VM120
10.0.1.120
↓

HEV120
↓

SOCKS5 Proxy #20
```

Each virtual machine owns an independent HEV tunnel.

No tunnel is shared.

---

## 2.2 Components

The project consists of several major components.

### Ubuntu Server

Acts as the gateway.

Responsibilities:

- IP forwarding
- Policy routing
- DHCP server
- Web UI
- HEV Tunnel

---

### HEV SOCKS5 Tunnel

Creates one tunnel for each virtual machine.

Example:

VM101

↓

hev101

↓

SOCKS5 Proxy

---

### ISC DHCP Server

Automatically assigns IP addresses.

Reserved IP addresses are bound to VM MAC addresses.

---

### Flask Web UI

Provides browser-based management.

Functions include:

- Add VM
- Delete VM
- Change Proxy
- DHCP Reservation
- Tunnel Control

---

## 2.3 Directory Layout

```
config/

examples/

scripts/

systemd/

webui/

docs/
```

---

## 2.4 Runtime Directories

During normal operation the gateway uses:

```
/etc/hev/

/usr/local/sbin/

/opt/proxy-gateway-ui/

/etc/dhcp/

/etc/iproute2/
```

---

# Chapter 3 - Hardware Requirements

## 3.1 Minimum

CPU

Dual-core x86_64

Memory

2 GB

Storage

8 GB SSD

Network

2 network interfaces

---

## 3.2 Recommended

CPU

Intel J1900

or newer

Memory

4 GB

Storage

32 GB SSD

Network

Gigabit Ethernet

---

## 3.3 Tested Hardware

The current version has been tested using:

Ubuntu Server 22.04 LTS

Intel J1900

4 GB RAM

Realtek Gigabit Ethernet

Intel Wireless Adapter

VMware Workstation

Windows 11

HEV SOCKS5 Tunnel

Flask Web UI

---

## 3.4 Network Recommendation

Use two independent interfaces.

WAN

Connected to Internet.

LAN

Connected to:

- VMware Host
- Proxmox
- Switch

Do not bridge WAN and LAN together.

This design guarantees correct policy routing.

---

End of Chapter 3.

---

# Chapter 4 - Software Requirements

## 4.1 Operating System

The current release has been developed and tested on:

- Ubuntu Server 22.04 LTS (64-bit)

Other Ubuntu releases may work but are not officially tested.

---

## 4.2 Required Packages

The following software components are required.

| Component | Purpose |
|-----------|---------|
| HEV SOCKS5 Tunnel | SOCKS5 tunnel |
| ISC DHCP Server | DHCP reservation |
| Unbound | Per-VM DNS forwarding and DNS fail-close |
| Flask | Web UI |
| Python 3 | Backend |
| systemd | Service management |

---

## 4.3 Browser Requirements

The Web UI has been tested using:

- Google Chrome
- Microsoft Edge

JavaScript must be enabled.

---

## 4.4 Network Interfaces

Default interface names used throughout this guide:

| Interface | Function |
|------------|----------|
| wlp2s0 | WAN |
| enp1s0 | LAN |

If your interface names are different, modify the configuration files before deployment.

---

## 4.5 Firewall

The current version assumes that Ubuntu Server is used as a trusted internal gateway.

No additional firewall configuration is required.

If a firewall is added later, ensure that:

- DHCP is allowed.
- DNS is allowed.
- HEV tunnels are not blocked.
- Policy routing remains functional.

---

# Chapter 5 - Network Architecture

## 5.1 Logical Topology

```
                     Internet
                         │
                  Home Router
                 192.168.2.1
                         │
                 WAN (wlp2s0)
             192.168.2.200/24
                         │
====================================================
              Ubuntu Proxy Gateway
====================================================
                 LAN (enp1s0)
                 10.0.1.1/24
                         │
        ┌───────────────┴───────────────┐
        │                               │
     VMware Host                    Proxmox
        │                               │
        └───────────────┬───────────────┘
                        │
                Virtual Machines
```

---

## 5.2 Address Allocation

Dynamic clients:

```
10.0.1.2
↓

10.0.1.99
```

Reserved VMs:

```
VM101 → 10.0.1.101

VM102 → 10.0.1.102

...

VM120 → 10.0.1.120
```

---

## 5.3 Packet Flow

The traffic path is:

```
VM

↓

Gateway

↓

Policy Routing

↓

HEV Tunnel

↓

SOCKS5 Proxy

↓

Internet
```

The guest operating system does not require any proxy configuration.

---

## 5.4 Fail-Close Design

Every VM has its own routing rule.

If a tunnel becomes unavailable:

- Internet access for that VM stops.
- No direct route to WAN is used.
- Other VMs continue working.

This prevents accidental IP leakage.

---

## 5.5 Independent Routing

Each VM owns:

- one routing table
- one HEV interface
- one SOCKS5 proxy
- one DHCP reservation

No routing table is shared.

---

# Chapter 6 - Ubuntu Server Installation

## 6.1 Installation Media

Download:

Ubuntu Server 22.04 LTS

Create a bootable USB drive.

---

## 6.2 Installation Options

During installation:

Language

English

Keyboard

Default

Storage

Use the entire disk.

Network

Configure later.

---

## 6.3 Create User

Example:

Username

```
ubuntu
```

Hostname

```
proxy-gateway
```

---

## 6.4 SSH Server

Install OpenSSH Server.

Remote management is strongly recommended.

---

## 6.5 First Boot

After installation:

Update the operating system.

```
sudo apt update

sudo apt upgrade -y
```

Reboot if required.

---

## 6.6 Verify Installation

Confirm:

```
hostname

ip address

systemctl status ssh
```

SSH should be active.

---

## 6.7 Next Step

The next chapter configures:

- WAN interface
- LAN interface
- DHCP
- DNS
- IP forwarding

Before continuing, ensure that Ubuntu boots normally and SSH access is working.

---

End of Chapter 6.

---

# Chapter 7 - Network Configuration

## 7.1 Overview

Proxy Gateway uses two independent network interfaces.

| Interface | Purpose |
|------------|----------|
| WAN | Internet connection |
| LAN | Virtual machine network |

The two interfaces must never be bridged together.

---

## 7.2 WAN Interface

The WAN interface connects the gateway to the existing home or office network.

Typical configuration:

| Parameter | Value |
|-----------|-------|
| Interface | wlp2s0 |
| Address | 192.168.2.200 |
| Gateway | 192.168.2.1 |

The WAN interface provides:

- Internet access
- DNS upstream
- SOCKS5 server connectivity

---

## 7.3 LAN Interface

The LAN interface serves all virtual machines.

Typical configuration:

| Parameter | Value |
|-----------|-------|
| Interface | enp1s0 |
| Address | 10.0.1.1/24 |

Virtual machines use:

Default Gateway

```
10.0.1.1
```

DNS Server

```
10.0.1.1
```

---

## 7.4 IP Forwarding

IPv4 forwarding must be enabled.

Verify:

```
cat /proc/sys/net/ipv4/ip_forward
```

Expected output:

```
1
```

---

## 7.5 Routing Policy

Each VM uses source-based routing.

Example:

| VM | Source Address | Routing Table |
|----|----------------|---------------|
| VM101 | 10.0.1.101 | hev101 |
| VM102 | 10.0.1.102 | hev102 |
| VM103 | 10.0.1.103 | hev103 |

Each routing table contains:

```
default dev hevXXX

10.0.1.0/24 dev enp1s0
```

---

## 7.6 Verification

Useful commands:

```
ip address

ip rule

ip route

ip route show table hev101
```

---

# Chapter 8 - DHCP Server Configuration

## 8.1 Purpose

The DHCP server automatically assigns IP addresses to clients.

Reserved addresses are created for managed virtual machines.

---

## 8.2 Dynamic Address Pool

Typical pool:

```
10.0.1.2

↓

10.0.1.99
```

Clients outside the managed VM range receive addresses from this pool.

---

## 8.3 Reserved Addresses

Managed VMs receive fixed addresses.

Example:

```
VM101

↓

10.0.1.101
```

```
VM102

↓

10.0.1.102
```

```
VM120

↓

10.0.1.120
```

---

## 8.4 DHCP Reservation

Every reservation contains:

- Host name
- MAC address
- Fixed IP address

Example:

```
host vm104 {

    hardware ethernet 00:0c:29:4e:24:6f;

    fixed-address 10.0.1.104;

}
```

---

## 8.5 Automatic Reservation

When adding a VM from the Web UI:

1. HEV instance is created.
2. DHCP reservation is created.
3. DHCP service is restarted.
4. Configuration is validated.

If validation fails:

- Previous configuration is restored automatically.

---

## 8.6 Verification

Useful commands:

```
systemctl status isc-dhcp-server

dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf

grep vm104 /etc/dhcp/dhcpd.conf
```

---

# Chapter 9 - HEV SOCKS5 Tunnel

## 9.1 Overview

Each VM owns one independent HEV tunnel.

Example:

```
VM104

↓

hev104

↓

SOCKS5 Proxy

↓

Internet
```

No tunnel is shared.

---

## 9.2 HEV Instance

Each instance contains:

```
config.yml

instance.conf
```

Location:

```
/etc/hev/104/
```

---

## 9.3 Interface Naming

Tunnel names:

```
hev101

hev102

hev103

...

hev120
```

Each interface owns one routing table.

---

## 9.4 Service Management

Every HEV instance is managed by systemd.

Examples:

```
hev-socks5-tunnel@101

hev-socks5-tunnel@102

hev-socks5-tunnel@103
```

Useful commands:

```
systemctl start hev-socks5-tunnel@104

systemctl stop hev-socks5-tunnel@104

systemctl restart hev-socks5-tunnel@104

systemctl status hev-socks5-tunnel@104
```

---

## 9.5 Proxy Assignment

Each tunnel stores:

- Proxy IP
- Proxy Port
- Username
- Password

The Web UI updates these values automatically.

---

## 9.6 Fail-Close

If the tunnel stops:

- Routing remains assigned to the tunnel.
- No direct WAN route is available.
- Internet access stops.
- Other VMs remain unaffected.

This behavior prevents traffic leakage.

---

## 9.7 Verification

Useful commands:

```
ip link show hev104

systemctl status hev-socks5-tunnel@104

ip rule

ip route show table hev104
```

---

End of Chapter 9.

---

# Chapter 10 - Web User Interface

## 10.1 Overview

The Web UI is the primary management interface of Proxy Gateway.

It allows administrators to manage virtual machines without manually editing configuration files or executing shell scripts.

Current version supports:

- Dashboard
- Add VM
- Delete VM
- Change Proxy
- DHCP Reservation
- Tunnel Control

---

## 10.2 Dashboard

The Dashboard displays all configured virtual machines.

Recommended screenshot:

### Figure 1 – Proxy Gateway Dashboard

![Proxy Gateway Dashboard](images/01-dashboard.png)

The Dashboard lists configured virtual machines, their LAN addresses,
assigned SOCKS5 proxies, tunnel interfaces, and current HEV status.

Displayed information includes:

| Column | Description |
|---------|-------------|
| VM | Virtual machine number |
| IP LAN | Assigned LAN IP address |
| MAC | DHCP reservation MAC |
| Tunnel | HEV interface |
| SOCKS5 | Proxy IP and Port |
| Username | SOCKS5 username |
| HEV Status | Running / Stopped |

---

## 10.3 VM Detail Page

Selecting a VM opens the detail page.

Recommended screenshot:

### Figure 2 – Virtual Machine Detail Page

![Virtual Machine Detail](images/02-vm-detail.png)

The VM Detail page provides DHCP reservation management, proxy settings,
tunnel controls, and the Delete VM function.

The page provides:

- VM information
- DHCP reservation
- SOCKS5 configuration
- Tunnel control
- Delete VM

---

## 10.4 Status Indicators

Running

```
Running
```

Stopped

```
Stopped
```

These values are obtained directly from systemd.

---

## 10.5 Navigation

Main pages:

```
Dashboard

↓

Add VM

↓

VM Detail
```

Navigation is intentionally simple to reduce operational errors.

---

# Chapter 11 - Creating a Virtual Machine

## 11.1 Overview

Creating a VM consists of two parts.

1. Create the guest operating system.
2. Register the VM inside Proxy Gateway.

The Web UI performs the second step.

---

## 11.2 Add VM Page

Recommended screenshot:

### Figure 3 – Add VM Form

![Add VM Form](images/03-add-vm.png)

Enter the VM number, MAC address, SOCKS5 server, port, username,
and password before creating the instance.

Required fields:

| Field | Description |
|-------|-------------|
| VM Number | 101–120 |
| MAC Address | Guest network adapter |
| Proxy IP | SOCKS5 server |
| Port | SOCKS5 port |
| Username | SOCKS5 username |
| Password | SOCKS5 password |

---

## 11.3 Validation

Before creating the VM, Proxy Gateway verifies:

- VM number
- MAC address format
- Proxy IP
- Proxy Port
- Username
- Password

Invalid values are rejected immediately.

---

## 11.4 Creation Process

The following operations are executed automatically.

Step 1

Create HEV instance.

↓

Step 2

Create routing table.

↓

Step 3

Create policy routing rule.

↓

Step 4

Generate HEV configuration.

↓

Step 5

Create DHCP reservation.

↓

Step 6

Restart DHCP server.

↓

Step 7

Start HEV tunnel.

↓

Step 8

Return to VM detail page.

---

## 11.5 Automatic Rollback

If DHCP reservation fails:

- HEV instance is removed.
- Routing table is removed.
- Policy routing rule is removed.
- Configuration is restored.

The system never leaves partially created VMs.

---

## 11.6 Verification

After successful creation verify:

- VM appears on Dashboard.
- HEV status is Running.
- VM receives the correct IP.
- Public IP matches the configured SOCKS5 proxy.

Recommended screenshot:

### Figure 4 – VM Creation Successful

![VM Creation Successful](images/04-add-vm-success.png)

After creation, the Web UI confirms the assigned LAN address and shows
the HEV tunnel in the Running state.

---

# Chapter 12 - Managing an Existing Virtual Machine

## 12.1 Overview

Once a VM has been created, all daily management tasks are performed from the VM Detail page.

---

## 12.2 Change DHCP Reservation

Update the MAC address if the virtual machine network adapter changes.

Workflow:

Edit MAC

↓

Save

↓

Restart DHCP

↓

New reservation becomes active

---

## 12.3 Change SOCKS5 Proxy

Recommended screenshot:

### Figure 5 – Proxy Update Successful

![Proxy Update Successful](images/05-change-proxy-success.png)

The success message confirms that the SOCKS5 configuration was updated
and the HEV service restarted successfully.

Editable fields:

- Proxy IP
- Port
- Username
- Password

The system automatically:

- validates the proxy
- updates configuration
- restarts the HEV service

---

## 12.4 Tunnel Control

Three operations are available.

### Start

Starts the HEV service.

---

### Restart

Restarts the tunnel without changing the configuration.

Useful after changing proxy settings.

---

### Stop

Stops the tunnel.

Fail-close behavior prevents direct Internet access.

---

## 12.5 Delete VM

Recommended screenshots:

### Figure 6 – Delete VM Confirmation

![Delete VM Confirmation](images/06-delete-confirm.png)

A confirmation dialog protects against accidentally deleting a VM
configuration.

### Figure 7 – Dashboard After VM Deletion

![Dashboard After VM Deletion](images/07-dashboard-after-delete.png)

The deleted VM no longer appears on the Dashboard.

### Figure 8 – Backend Verification After Deletion

![Backend Verification After Deletion](images/08-terminal-after-delete.png)

The terminal output confirms that the HEV service is inactive and that
the VM policy-routing rule has been removed.

Deleting a VM automatically performs:

- Stop HEV service
- Remove HEV configuration
- Remove routing table
- Remove policy routing rule
- Remove tunnel interface
- Remove DHCP reservation
- Remove systemd state

A confirmation dialog is displayed before deletion.

---

## 12.6 Re-create VM

A deleted VM may be created again using the same:

- VM number
- MAC address
- SOCKS5 proxy

The gateway rebuilds all required resources automatically.

---

## 12.7 Verification

After recreation verify:

- Dashboard displays the VM.
- Tunnel is Running.
- DHCP reservation exists.
- Public IP matches the SOCKS5 proxy.

This workflow has been validated during the v1.0.3 system tests.

---

End of Chapter 12.

---

# Chapter 13 - Backup and Restore

## 13.1 Overview

Regular backups are strongly recommended before:

- upgrading the software
- modifying network settings
- changing DHCP configuration
- updating Web UI components

The gateway stores configuration in plain text files, making backup and restore straightforward.

---

## 13.2 Important Directories

The following locations should be included in every backup.

| Directory | Purpose |
|-----------|---------|
| /etc/hev | HEV instance configurations |
| /etc/dhcp | DHCP server configuration |
| /usr/local/sbin | Management scripts |
| /opt/proxy-gateway-ui | Flask Web UI |
| /etc/iproute2 | Routing table definitions |

---

## 13.3 Creating a Backup

Example:

```bash
sudo tar czf proxy-gateway-backup.tar.gz \
/etc/hev \
/etc/dhcp \
/usr/local/sbin \
/opt/proxy-gateway-ui \
/etc/iproute2
```

Store the archive outside the gateway whenever possible.

---

## 13.4 Restoring a Backup

Extract the archive:

```bash
sudo tar xzf proxy-gateway-backup.tar.gz -C /
```

Restart the required services:

```bash
sudo systemctl restart isc-dhcp-server

sudo systemctl restart proxy-gateway-ui
```

Restart individual HEV tunnels if required.

---

## 13.5 Backup Verification

Verify:

- HEV configuration exists.
- DHCP reservations exist.
- Web UI starts successfully.
- Virtual machines obtain the correct IP addresses.

---

## 13.6 Git Repository Backup

The project source code is maintained in Git.

Recommended workflow:

```text
Commit

↓

Push

↓

Create Tag

↓

Create Release
```

This preserves the complete development history.

---

# Chapter 14 - Troubleshooting

## 14.1 HEV Service Does Not Start

Check:

```bash
systemctl status hev-socks5-tunnel@104
```

Review logs:

```bash
journalctl -u hev-socks5-tunnel@104
```

---

## 14.2 DHCP Server Fails

Validate configuration:

```bash
dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf
```

Restart:

```bash
systemctl restart isc-dhcp-server
```

---

## 14.3 VM Cannot Access the Internet

Verify:

```bash
ip rule

ip route

systemctl status hev-socks5-tunnel@104
```

Confirm that:

- the HEV tunnel is running
- the routing table exists
- the SOCKS5 proxy is reachable

---

## 14.4 Wrong Public IP

Check:

- Proxy IP
- Proxy Port
- Username
- Password

Update the proxy from the Web UI if required.

---

## 14.5 Web UI Does Not Load

Check service status:

```bash
systemctl status proxy-gateway-ui
```

Review logs:

```bash
journalctl -u proxy-gateway-ui
```

---

## 14.6 Add VM Fails

Possible causes:

- Invalid MAC address
- Duplicate DHCP reservation
- Invalid proxy
- Existing VM number
- HEV configuration error

The gateway automatically rolls back failed operations.

---

## 14.7 Delete VM Fails

Verify:

- HEV service status
- DHCP server status
- File permissions
- systemd logs

If rollback is triggered, investigate the reported error before retrying.

---

## 14.8 Useful Commands

```bash
ip address

ip rule

ip route

systemctl

journalctl

dhcpd -t

hostname

ping

curl https://ifconfig.me
```

---

# Chapter 15 - Appendix

## 15.1 Project Directory

```
config/
docs/
examples/
scripts/
systemd/
webui/
```

---

## 15.2 Runtime Directories

```
/etc/hev/

/etc/dhcp/

/usr/local/sbin/

/opt/proxy-gateway-ui/

/etc/iproute2/
```

---

## 15.3 Naming Convention

| Item | Example |
|------|---------|
| VM | VM104 |
| Tunnel | hev104 |
| Routing Table | hev104 |
| Service | hev-socks5-tunnel@104 |

---

## 15.4 Tested Environment

Operating System

Ubuntu Server 22.04 LTS

Gateway Hardware

Intel J1900

Memory

4 GB

Guest Platform

VMware Workstation

Networking

Source-based policy routing

Tunnel

HEV SOCKS5 Tunnel

Management

Flask Web UI

---

## 15.5 Version History

| Version | Description |
|----------|-------------|
| v1.0.1 | Initial public release |
| v1.0.3 | Delete VM, DHCP cleanup, improved rollback, Web UI enhancements |

---

## 15.6 License

This project is distributed under the MIT License.

See the LICENSE file for details.

---

# End of Document

---

# v1.0.3 Addendum - Per-VM DNS and DNS Fail-Close

v1.0.3 adds one independent Unbound instance per VM. VM DNS is redirected from port 53 to a dedicated listener on `10.0.1.1`; Unbound then uses `198.19.<INSTANCE>.1` as its source address and policy-routes upstream DNS through the matching `hev<INSTANCE>` table.

```text
DNS_SOURCE_IP=198.19.<INSTANCE>.1
DNS_PORT=53000+INSTANCE
DNS_RULE_PRIORITY=INSTANCE+1000
DNS_BLOCK_PRIORITY=INSTANCE+1100
DNS_SERVICE=proxy-gateway-dns@<INSTANCE>.service
DNS_CONFIG=/etc/unbound/proxy-gateway/vm<INSTANCE>.conf
```

Example: VM104 uses `10.0.1.1:53104`, source `198.19.104.1`, and table `hev104`.

`add-hev-instance.sh` provisions the DNS config, source address, DNS policy
rules, UDP/TCP redirects, and `proxy-gateway-dns@<INSTANCE>.service`. Rollback
removes both HEV and DNS state.

`remove-hev-instance.sh` stops/disables the DNS service and removes the DNS
config, source address, policy rules, redirects, and HEV resources.

`dns-instance-up.sh` is executed before Unbound to rebuild per-VM DNS runtime
state after reboot or service restart.

The systemd template is:

```text
/etc/systemd/system/proxy-gateway-dns@.service
```

Per-VM Unbound uses TCP upstream, `outgoing-interface:
198.19.<INSTANCE>.1`, `do-ip6: no`, `forward-first: no`, and:

```yaml
remote-control:
    control-enable: no
```

Disabling remote control prevents multiple Unbound processes from competing
for control port `127.0.0.1:8953`.

## Verification

```bash
systemctl is-active proxy-gateway-dns@104
sudo ss -lntup | grep 53104
ip addr show lo | grep 198.19.104.1
ip rule | grep -E '10\.0\.1\.104|198\.19\.104\.1'
ip route get 8.8.8.8 from 198.19.104.1
dig @10.0.1.1 -p 53104 dnsleaktest.com
sudo iptables -t nat -S PREROUTING | grep -E '10\.0\.1\.104|53104'
```

With HEV active, routing must select `dev hev104 table hev104` and DNS must
resolve successfully.

## DNS fail-close

```bash
sudo systemctl stop hev-socks5-tunnel@104
ip route get 8.8.8.8 from 198.19.104.1
```

The route test must return `Network is unreachable`. A fresh DNS query from
VM104 and Internet access must fail; DNS must not fall back to the direct WAN.

After:

```bash
sudo systemctl start hev-socks5-tunnel@104
```

DNS and Internet access must recover through the proxy.

Note: DNS generated by the Ubuntu gateway itself or management applications
may still appear on WAN. VM leak testing should filter by the VM address and
`198.19.<INSTANCE>.1`.
