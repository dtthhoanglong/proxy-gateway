# Proxy Gateway v1.0

Ubuntu-based multi-VM SOCKS5 gateway using HEV SOCKS5 Tunnel, source-based policy routing, ISC DHCP Server, dnsmasq, and a Flask Web UI.

## Features

- One HEV SOCKS5 tunnel per VM
- Source-based policy routing
- DHCP reservations by MAC address
- Start, stop, and restart individual HEV instances
- Change SOCKS5 proxy through Web UI
- Add new VM through Web UI
- Fail-close behavior when a tunnel is stopped
- Automatic configuration backups and cleanup
- Lightweight design for low-power hardware

## Default network layout

- WAN interface: `wlp2s0`
- WAN gateway: `192.168.2.1`
- LAN interface: `enp1s0`
- LAN gateway: `10.0.1.1/24`
- Managed VM range: `VM101` to `VM120`
- Web UI: `http://10.0.1.1:8080`

## Project structure

```text
config/          System configuration examples
docs/            Installation and administration documentation
examples/hev/    Example HEV instance configuration
scripts/         Gateway automation scripts
systemd/         systemd service units
webui/           Flask and Gunicorn Web UI
```

## Security notice

Do not commit real production SOCKS5 usernames, passwords, or private proxy endpoints.

## Current limitations

- DNS requests are still forwarded directly through the WAN in v1.0.
- DNS leak protection is planned for v2.0.
- Web UI is intended for trusted LAN access only.
- HTTPS and authentication are not included in v1.0.

## License

MIT
