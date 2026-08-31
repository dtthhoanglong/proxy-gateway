# Proxy Gateway

Ubuntu-based multi-VM SOCKS5 gateway using HEV SOCKS5 Tunnel, IPv4/IPv6 policy routing, ISC DHCP Server, per-instance Unbound DNS, and a Flask Web UI.

## Features

- One HEV SOCKS5 tunnel per VM
- VM range from VM101 to VM120
- Separate SOCKS5 IPv4 and SOCKS5 IPv6 modes
- IPv4 and IPv6 source-based policy routing
- One MAC mapping per VM/proxy mode
- DHCPv4 reservations by MAC for IPv4 clients
- IPv6 client mapping support
- Add and delete VM from Web UI
- Change SOCKS5 proxy from Web UI
- Start, stop, and restart individual tunnels
- Fail-close behavior
- Automatic rollback
- Automatic configuration backups
- Lightweight design for low-power hardware
- Per-VM DNS Leak Protection
- Per-VM Unbound DNS Resolver
- DNS upstream forced through HEV/SOCKS5 using TCP
- DNS fail-close protection
- Automatic DNS provisioning and cleanup

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
                      WAN interface
               DHCPv4 + IPv6 Router Advertisement
                            |
                    Ubuntu Proxy Gateway
                            |
                       LAN interface
              10.0.1.1/24 + fd10:0:1::1/64
                            |
                    VM101 ... VM120
          IPv4: 10.0.1.101 ... 10.0.1.120
          IPv6: fd10:0:1::101 ... ::120
```

WAN and LAN interface names are selected for the target machine instead of being hard-coded.

IPv4 clients use DHCPv4 reservations. IPv6 mode currently uses the configured IPv6 client address/mapping; it is not a DHCPv6 implementation.
