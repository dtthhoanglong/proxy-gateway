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

# Chapter 1 - Disable Cloud-Init

## 1.1 Overview

Ubuntu Server may use Cloud-Init to regenerate network configuration
during boot.

Proxy Gateway manages networking through Netplan.

Cloud-Init network management must therefore be disabled before any
network configuration changes are made.

---

## 1.2 Disable Cloud-Init Network Configuration

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

End of Chapter 1

---

# Chapter 2 - Configure Network

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

End of Chapter 2

---

# Chapter 3 - Enable IPv4 Forwarding

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

## 3.3 Enable IPv4 Forwarding

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

Expected output:

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

End of Chapter 3

---

# Chapter 4 - Install and Configure ISC DHCP Server

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

End of Chapter 4

---

# Chapter 5 - Deploy HEV Runtime

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

## 5.2 Install HEV SOCKS5 Tunnel

Download the latest release from the official HEV repository.

Install the binary.

Example:

```bash
sudo install -m 755 hev-socks5-tunnel \
/usr/local/bin/hev-socks5-tunnel
```

Verify installation.

```bash
hev-socks5-tunnel --version
```

Expected result.

The installed version is displayed.

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

End of Chapter 5

---

# Chapter 6 - Deploy Configuration Files

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

End of Chapter 6
