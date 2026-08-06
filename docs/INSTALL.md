# Proxy Gateway Installation Guide

Version: **v1.0.2**

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
