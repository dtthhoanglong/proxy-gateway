# Changelog

## v1.0.3

### Added

- Per-VM DNS leak protection.
- Dedicated Unbound resolver instance for each managed VM.
- Per-VM DNS source addresses using `198.19.<INSTANCE>.1`.
- Per-VM DNS listener ports using `53<INSTANCE>`.
- DNS upstream forwarding forced over TCP through the assigned HEV tunnel.
- DNS fail-close policy using a dedicated `unreachable` rule.
- Automatic DNS redirect from VM traffic on port 53 to the corresponding Unbound instance.
- New `dns-instance-up.sh` management script.
- New `proxy-gateway-dns@.service` systemd template.

### Changed

- `add-hev-instance.sh` now provisions DNS isolation automatically.
- `remove-hev-instance.sh` now removes DNS services, rules, addresses, redirects, and configuration.
- DNS traffic no longer uses the gateway WAN resolver path for managed VMs.

### Tested

- DNS resolution through HEV/SOCKS5.
- DNS fail-close when HEV is stopped.
- Internet fail-close when HEV is stopped.
- Automatic DNS recovery after HEV restart.
- Complete cleanup after deleting a VM instance.

All notable changes to this project are documented in this file.

The format is based on Keep a Changelog.

---

## [v1.0.2] - 2026-08-06

### Added

- Added **Delete VM** function to the Web UI.
- Added confirmation dialog before deleting a VM.
- Automatically removes DHCP reservation when deleting a VM.
- Added rollback handling if VM deletion encounters an error.

### Improved

- Improved DHCP reservation rollback logic.
- Improved SOCKS5 proxy update validation.
- Added validation that all required SOCKS5 fields are updated.
- Backup cleanup is now optional if the cleanup script is not installed.
- VM ID suggestion now starts from `MIN_INSTANCE`.

### Fixed

- Fixed accidental shell wrapper text stored in `index.html`.
- Improved robustness of configuration update scripts.
- Improved backup cleanup handling.
- Various stability improvements.

---

## [v1.0.1] - 2026-08-06

### Initial Release

Features:

- HEV SOCKS5 tunnel per VM
- Source-based policy routing
- DHCP reservation management
- Flask Web UI
- Add VM
- Change SOCKS5 proxy
- Start / Stop / Restart tunnel
- Automatic rollback on creation failure
- Automatic configuration backup
