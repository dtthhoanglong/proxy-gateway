#!/bin/bash
set -euo pipefail

HEV_VERSION="2.14.4"
HEV_URL="https://github.com/heiher/hev-socks5-tunnel/releases/download/${HEV_VERSION}/hev-socks5-tunnel-linux-x86_64"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die(){ echo "ERROR: $*" >&2; exit 1; }
ok(){ echo "PASS: $*"; }
need_file(){ [ -f "$1" ] || die "Missing repository file: $1"; }

[ "$(id -u)" -eq 0 ] || die "Run with: sudo ./install.sh"
[ "$(uname -m)" = "x86_64" ] || die "This installer currently supports x86_64 only."
cd "$SCRIPT_DIR"

echo
printf '%s\n' '======================================================' '             Proxy Gateway Installer' '======================================================'
echo

for f in \
  config/dhcpd.conf \
  scripts/add-hev-instance.sh scripts/change-proxy.sh scripts/cleanup-hev-backups.sh \
  scripts/dns-instance-up.sh scripts/hev-instance-up.sh scripts/remove-hev-instance.sh \
  scripts/set-dhcp-reservation.sh scripts/proxy-gateway-set-nics scripts/proxy-gateway-firstboot \
  systemd/hev-socks5-tunnel@.service systemd/proxy-gateway-dns@.service \
  systemd/proxy-gateway-ui.service systemd/proxy-gateway-firstboot.service \
  webui/app.py; do
  need_file "$f"
done

echo '[1/10] Installing packages...'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  isc-dhcp-server wget git netcat-openbsd iptables python3 python3-pip \
  python3-flask gunicorn unbound radvd dnsutils
systemctl disable --now unbound 2>/dev/null || true

echo '[2/10] Disabling Cloud-Init network management...'
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'CFG'
network: {config: disabled}
CFG
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl mask systemd-networkd-wait-online.service

echo "[3/10] Installing HEV SOCKS5 Tunnel ${HEV_VERSION}..."
tmp_hev="$(mktemp)"
trap 'rm -f "$tmp_hev"' EXIT
wget -q --show-progress -O "$tmp_hev" "$HEV_URL"
install -o root -g root -m 755 "$tmp_hev" /usr/local/bin/hev-socks5-tunnel
mkdir -p /etc/hev
/usr/local/bin/hev-socks5-tunnel --version
ok 'HEV installed'

echo '[4/10] Installing Proxy Gateway scripts...'
install -o root -g root -m 750 \
  scripts/add-hev-instance.sh scripts/change-proxy.sh scripts/cleanup-hev-backups.sh \
  scripts/dns-instance-up.sh scripts/hev-instance-up.sh scripts/remove-hev-instance.sh \
  scripts/set-dhcp-reservation.sh scripts/proxy-gateway-set-nics scripts/proxy-gateway-firstboot \
  /usr/local/sbin/
for f in \
  /usr/local/sbin/add-hev-instance.sh /usr/local/sbin/change-proxy.sh \
  /usr/local/sbin/cleanup-hev-backups.sh /usr/local/sbin/dns-instance-up.sh \
  /usr/local/sbin/hev-instance-up.sh /usr/local/sbin/remove-hev-instance.sh \
  /usr/local/sbin/set-dhcp-reservation.sh /usr/local/sbin/proxy-gateway-set-nics \
  /usr/local/sbin/proxy-gateway-firstboot; do
  bash -n "$f"
done
ok 'Management scripts installed'

echo '[5/10] Installing DHCP configuration...'
install -o root -g root -m 644 config/dhcpd.conf /etc/dhcp/dhcpd.conf
dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf
ok 'DHCP configuration valid'

echo '[6/10] Installing systemd units...'
install -o root -g root -m 644 systemd/hev-socks5-tunnel@.service /etc/systemd/system/hev-socks5-tunnel@.service
install -o root -g root -m 644 systemd/proxy-gateway-dns@.service /etc/systemd/system/proxy-gateway-dns@.service
install -o root -g root -m 644 systemd/proxy-gateway-ui.service /etc/systemd/system/proxy-gateway-ui.service
install -o root -g root -m 644 systemd/proxy-gateway-firstboot.service /etc/systemd/system/proxy-gateway-firstboot.service
systemctl daemon-reload
systemctl disable proxy-gateway-firstboot.service 2>/dev/null || true

echo '[7/10] Installing Web UI...'
mkdir -p /opt/proxy-gateway-ui
rm -rf /opt/proxy-gateway-ui/*
cp -a webui/. /opt/proxy-gateway-ui/
python3 -m py_compile /opt/proxy-gateway-ui/app.py
ok 'Web UI installed'

echo '[8/10] Selecting WAN and LAN interfaces...'
mapfile -t NICS < <(
  for p in /sys/class/net/*; do
    [ -e "$p" ] || continue
    nic="$(basename "$p")"
    [ "$nic" = lo ] && continue
    case "$nic" in
      hev*|tun*|tap*|veth*|docker*|br-*|virbr*|vmnet*|wg*|ppp*) continue ;;
    esac
    [ -e "$p/device" ] || continue
    printf '%s\n' "$nic"
  done | sort
)
[ "${#NICS[@]}" -ge 2 ] || die 'At least two usable network interfaces are required.'

show_interfaces(){
  echo
  echo 'Available network interfaces:'
  echo
  local i nic mac state
  for i in "${!NICS[@]}"; do
    nic="${NICS[$i]}"
    mac="$(cat "/sys/class/net/$nic/address" 2>/dev/null || echo '?')"
    state="$(cat "/sys/class/net/$nic/operstate" 2>/dev/null || echo '?')"
    printf '  %d) %-16s MAC %-17s state=%s\n' "$((i+1))" "$nic" "$mac" "$state"
  done
  echo
}

read_choice(){
  local prompt="$1" value
  while true; do
    read -r -p "$prompt" value
    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le "${#NICS[@]}" ]; then
      REPLY="${NICS[$((value-1))]}"
      return
    fi
    echo "Invalid selection. Choose 1-${#NICS[@]}."
  done
}

while true; do
  show_interfaces
  read_choice 'Select WAN interface number: '
  WAN_IF="$REPLY"
  read_choice 'Select LAN interface number: '
  LAN_IF="$REPLY"
  if [ "$WAN_IF" = "$LAN_IF" ]; then
    echo 'WAN and LAN cannot be the same interface.'
    continue
  fi
  echo
  echo "Selected: WAN=$WAN_IF  LAN=$LAN_IF"
  read -r -p 'Apply this network configuration? [y/N]: ' confirm
  case "$confirm" in y|Y|yes|YES) break ;; *) echo 'Selection cancelled. Choose again.' ;; esac
done

echo '[9/10] Applying network configuration...'
echo 'NOTE: SSH may pause briefly while Netplan is applied.'
/usr/local/sbin/proxy-gateway-set-nics "$WAN_IF" "$LAN_IF"
ok 'Network configuration applied'

echo '[10/10] Starting services and running checks...'
systemctl enable --now isc-dhcp-server
systemctl enable --now radvd
systemctl enable --now proxy-gateway-ui.service

fail=0
check(){
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$description"; else echo "FAIL: $description"; fail=1; fi
}

check 'IPv4 forwarding enabled' test "$(sysctl -n net.ipv4.ip_forward)" = 1
check 'IPv6 forwarding enabled' test "$(sysctl -n net.ipv6.conf.all.forwarding)" = 1
check 'DHCP service active' systemctl is-active --quiet isc-dhcp-server
check 'radvd service active' systemctl is-active --quiet radvd
check 'Web UI service active' systemctl is-active --quiet proxy-gateway-ui.service
check 'WAN IPv4 default route present' sh -c "ip route show default dev '$WAN_IF' | grep -q '^default '"
check 'network.conf created' test -s /etc/proxy-gateway/network.conf
check 'radvd uses selected LAN' grep -q "^interface ${LAN_IF}$" /etc/radvd.conf
check 'DHCP uses selected LAN' grep -q "^INTERFACESv4=\"${LAN_IF}\"$" /etc/default/isc-dhcp-server

if ip -4 addr show dev "$LAN_IF" | grep -q '10\.0\.1\.1/24'; then ok 'LAN IPv4 10.0.1.1/24 present'; else echo 'FAIL: LAN IPv4 10.0.1.1/24 missing'; fail=1; fi
if ip -6 addr show dev "$LAN_IF" | grep -q 'fd10:0:1::1/64'; then ok 'LAN IPv6 fd10:0:1::1/64 present'; else echo 'FAIL: LAN IPv6 fd10:0:1::1/64 missing'; fail=1; fi

health_ok=0
for _ in $(seq 1 15); do
  if curl -fsS --max-time 2 http://10.0.1.1:8080/health >/dev/null 2>&1; then health_ok=1; break; fi
  sleep 1
done
if [ "$health_ok" -eq 1 ]; then ok 'Web UI health endpoint'; else echo 'FAIL: Web UI health endpoint'; fail=1; fi

echo
printf '%s\n' '======================================================'
if [ "$fail" -eq 0 ]; then
  echo ' Proxy Gateway installation complete: PASS'
  echo ' Web UI: http://10.0.1.1:8080/'
else
  echo ' Proxy Gateway installation completed with FAIL checks'
  echo ' Review the FAIL lines above before adding VM instances.'
fi
echo " WAN: $WAN_IF"
echo " LAN: $LAN_IF"
printf '%s\n' '======================================================'
echo
exit "$fail"
