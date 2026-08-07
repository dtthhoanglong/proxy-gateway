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

## Documentation

### English

- [Installation Guide](docs/INSTALL_EN.md)
- [Deployment Guide](docs/DEPLOYMENT_GUIDE_EN.md)
- [Source Code Guide](docs/SOURCE_CODE_GUIDE_EN.md)

### Tiếng Việt

- [Hướng dẫn cài đặt](docs/INSTALL_VI.md)
- [Hướng dẫn triển khai](docs/DEPLOYMENT_GUIDE_VI.md)
- [Hướng dẫn phân tích mã nguồn](docs/SOURCE_CODE_GUIDE_VI.md)

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

