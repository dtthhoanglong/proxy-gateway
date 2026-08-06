# Proxy Gateway v1.0.2

Ubuntu-based multi-VM SOCKS5 gateway using HEV SOCKS5 Tunnel, policy routing, ISC DHCP Server, dnsmasq, and a Flask Web UI.

## Features

- One HEV SOCKS5 tunnel per VM
- VM range from VM101 to VM120
- Source-based policy routing
- DHCP reservations by MAC address
- Add and delete VM from Web UI
- Change SOCKS5 proxy from Web UI
- Start, stop, and restart individual tunnels
- Fail-close behavior
- Automatic rollback
- Automatic configuration backups
- Lightweight design for low-power hardware

## Network Layout

```text
Internet
   |
WAN: wlp2s0
192.168.2.200
   |
Ubuntu Proxy Gateway
LAN: enp1s0
10.0.1.1/24
   |
VM101 - VM120
10.0.1.101 - 10.0.1.120
