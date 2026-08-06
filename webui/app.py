from __future__ import annotations

import ipaddress
import re
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any

from flask import (
    Flask,
    flash,
    redirect,
    render_template,
    request,
    url_for,
)

app = Flask(__name__)
app.secret_key = "proxy-gateway-local-ui"

DHCP_CONFIG = Path("/etc/dhcp/dhcpd.conf")
HEV_ROOT = Path("/etc/hev")

ADD_INSTANCE_SCRIPT = Path(
    "/usr/local/sbin/add-hev-instance.sh"
)
SET_RESERVATION_SCRIPT = Path(
    "/usr/local/sbin/set-dhcp-reservation.sh"
)
REMOVE_INSTANCE_SCRIPT = Path(
    "/usr/local/sbin/remove-hev-instance.sh"
)
CHANGE_PROXY_SCRIPT = Path(
    "/usr/local/sbin/change-proxy.sh"
)

MIN_INSTANCE = 101
MAX_INSTANCE = 120


def valid_instance(instance: int) -> bool:
    return MIN_INSTANCE <= instance <= MAX_INSTANCE


def normalize_mac(value: str) -> str:
    return value.strip().lower().replace("-", ":")


def valid_mac(value: str) -> bool:
    mac = normalize_mac(value)
    return bool(
        re.fullmatch(
            r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}",
            mac,
        )
    )


def run_command(
    command: list[str],
    timeout: int = 45,
) -> tuple[bool, str]:
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return False, "Lệnh đã quá thời gian chờ."
    except OSError as exc:
        return False, str(exc)

    output = "\n".join(
        part.strip()
        for part in (result.stdout, result.stderr)
        if part.strip()
    )

    return result.returncode == 0, output


def parse_reservations() -> dict[int, dict[str, str]]:
    reservations: dict[int, dict[str, str]] = {}

    if not DHCP_CONFIG.exists():
        return reservations

    text = DHCP_CONFIG.read_text(errors="replace")

    blocks = re.findall(
        r"host\s+([A-Za-z0-9_-]+)\s*\{(.*?)\}",
        text,
        flags=re.DOTALL,
    )

    for host_name, body in blocks:
        vm_match = re.fullmatch(
            r"vm(\d+)",
            host_name,
            re.IGNORECASE,
        )

        if not vm_match:
            continue

        instance = int(vm_match.group(1))

        if not valid_instance(instance):
            continue

        mac_match = re.search(
            r"hardware\s+ethernet\s+"
            r"([0-9a-fA-F:-]+)\s*;",
            body,
        )

        ip_match = re.search(
            r"fixed-address\s+"
            r"(\d+\.\d+\.\d+\.\d+)\s*;",
            body,
        )

        reservations[instance] = {
            "mac": (
                normalize_mac(mac_match.group(1))
                if mac_match
                else ""
            ),
            "ip": (
                ip_match.group(1)
                if ip_match
                else f"10.0.1.{instance}"
            ),
        }

    return reservations


def parse_hev_config(instance: int) -> dict[str, str]:
    config_path = HEV_ROOT / str(instance) / "config.yml"

    result = {
        "proxy_ip": "",
        "proxy_port": "",
        "proxy_username": "",
        "tunnel": f"hev{instance}",
    }

    if not config_path.exists():
        return result

    text = config_path.read_text(errors="replace")

    tunnel_match = re.search(
        r"(?ms)^tunnel:\s*$.*?"
        r"^\s+name:\s*(\S+)\s*$",
        text,
    )

    socks_match = re.search(
        r"(?ms)^socks5:\s*$"
        r"(.*?)(?=^[^\s]|\Z)",
        text,
    )

    if tunnel_match:
        result["tunnel"] = tunnel_match.group(1).strip()

    if socks_match:
        body = socks_match.group(1)

        address_match = re.search(
            r"^\s+address:\s*(.+?)\s*$",
            body,
            flags=re.MULTILINE,
        )
        port_match = re.search(
            r"^\s+port:\s*(\d+)\s*$",
            body,
            flags=re.MULTILINE,
        )
        username_match = re.search(
            r"^\s+username:\s*(.+?)\s*$",
            body,
            flags=re.MULTILINE,
        )

        if address_match:
            result["proxy_ip"] = address_match.group(1).strip()

        if port_match:
            result["proxy_port"] = port_match.group(1).strip()

        if username_match:
            result["proxy_username"] = (
                username_match.group(1).strip()
            )

    return result


def service_name(instance: int) -> str:
    return f"hev-socks5-tunnel@{instance}.service"


def service_is_active(instance: int) -> bool:
    success, _ = run_command(
        [
            "systemctl",
            "is-active",
            "--quiet",
            service_name(instance),
        ],
        timeout=5,
    )
    return success


def configured_instances() -> set[int]:
    instances: set[int] = set()

    if not HEV_ROOT.exists():
        return instances

    try:
        entries = list(HEV_ROOT.iterdir())
    except OSError:
        return instances

    for entry in entries:
        if not entry.is_dir() or not entry.name.isdigit():
            continue

        instance = int(entry.name)

        if not valid_instance(instance):
            continue

        if (entry / "config.yml").exists():
            instances.add(instance)

    return instances


def build_vm(instance: int) -> dict[str, Any]:
    reservations = parse_reservations()
    reservation = reservations.get(instance, {})
    hev = parse_hev_config(instance)

    config_exists = (
        HEV_ROOT / str(instance) / "config.yml"
    ).exists()

    return {
        "instance": instance,
        "name": f"VM{instance}",
        "ip": reservation.get(
            "ip",
            f"10.0.1.{instance}",
        ),
        "mac": reservation.get("mac", ""),
        "tunnel": hev["tunnel"],
        "proxy_ip": hev["proxy_ip"],
        "proxy_port": hev["proxy_port"],
        "proxy_username": hev["proxy_username"],
        "hev_configured": config_exists,
        "hev_active": (
            service_is_active(instance)
            if config_exists
            else False
        ),
    }


def build_vm_list() -> list[dict[str, Any]]:
    reservations = set(parse_reservations().keys())
    hev_instances = configured_instances()
    instances = sorted(reservations | hev_instances)

    return [
        build_vm(instance)
        for instance in instances
        if valid_instance(instance)
    ]


@app.route("/")
def index():
    return render_template(
        "index.html",
        vms=build_vm_list(),
        generated_at=datetime.now().strftime(
            "%Y-%m-%d %H:%M:%S"
        ),
    )


@app.route("/vm/add", methods=["GET", "POST"])
def add_vm():
    if request.method == "GET":
        used_instances = (
            set(parse_reservations().keys())
            | configured_instances()
        )

        suggested_instance = next(
            (
                number
                for number in range(104, MAX_INSTANCE + 1)
                if number not in used_instances
            ),
            104,
        )

        return render_template(
            "add_vm.html",
            suggested_instance=suggested_instance,
        )

    instance_text = request.form.get(
        "instance",
        "",
    ).strip()
    mac = request.form.get("mac", "").strip()
    proxy_ip = request.form.get(
        "proxy_ip",
        "",
    ).strip()
    proxy_port = request.form.get(
        "proxy_port",
        "",
    ).strip()
    username = request.form.get(
        "username",
        "",
    ).strip()
    password = request.form.get(
        "password",
        "",
    )

    if not instance_text.isdigit():
        flash("Số VM không hợp lệ.", "error")
        return redirect(url_for("add_vm"))

    instance = int(instance_text)

    if not valid_instance(instance):
        flash(
            "Số VM phải nằm trong khoảng 101–120.",
            "error",
        )
        return redirect(url_for("add_vm"))

    if (
        instance in parse_reservations()
        or instance in configured_instances()
    ):
        flash(
            f"VM{instance} đã tồn tại.",
            "error",
        )
        return redirect(url_for("add_vm"))

    if not valid_mac(mac):
        flash("Địa chỉ MAC không hợp lệ.", "error")
        return redirect(url_for("add_vm"))

    try:
        ipaddress.ip_address(proxy_ip)
    except ValueError:
        flash("Địa chỉ proxy không hợp lệ.", "error")
        return redirect(url_for("add_vm"))

    if (
        not proxy_port.isdigit()
        or not 1 <= int(proxy_port) <= 65535
    ):
        flash("Port proxy không hợp lệ.", "error")
        return redirect(url_for("add_vm"))

    if not username or not password:
        flash(
            "Username và password không được để trống.",
            "error",
        )
        return redirect(url_for("add_vm"))

    add_success, add_output = run_command(
        [
            str(ADD_INSTANCE_SCRIPT),
            str(instance),
            proxy_ip,
            proxy_port,
            username,
            password,
        ],
        timeout=60,
    )

    if not add_success:
        flash(
            add_output or "Không thể tạo HEV instance.",
            "error",
        )
        return redirect(url_for("add_vm"))

    reservation_success, reservation_output = run_command(
        [
            str(SET_RESERVATION_SCRIPT),
            str(instance),
            mac,
        ],
        timeout=45,
    )

    if not reservation_success:
        rollback_success, rollback_output = run_command(
            [
                str(REMOVE_INSTANCE_SCRIPT),
                str(instance),
            ],
            timeout=45,
        )

        if rollback_success:
            flash(
                "Gán DHCP reservation thất bại. "
                f"HEV instance VM{instance} đã được rollback sạch.\n"
                + (
                    reservation_output
                    or "Không rõ nguyên nhân DHCP."
                ),
                "error",
            )
            return redirect(url_for("add_vm"))

        flash(
            "Gán DHCP reservation thất bại và rollback HEV cũng thất bại.\n"
            "Cần kiểm tra thủ công trước khi thử lại.\n\n"
            "Lỗi DHCP:\n"
            + (
                reservation_output
                or "Không rõ nguyên nhân DHCP."
            )
            + "\n\nLỗi rollback:\n"
            + (
                rollback_output
                or "Không rõ nguyên nhân rollback."
            ),
            "error",
        )
        return redirect(
            url_for("vm_detail", instance=instance)
        )

    flash(
        f"Đã tạo VM{instance}, gán IP "
        f"10.0.1.{instance} và khởi động HEV.",
        "success",
    )

    return redirect(
        url_for("vm_detail", instance=instance)
    )


@app.route("/vm/<int:instance>")
def vm_detail(instance: int):
    if not valid_instance(instance):
        return "VM không hợp lệ", 404

    return render_template(
        "vm.html",
        vm=build_vm(instance),
    )


@app.post("/vm/<int:instance>/reservation")
def set_reservation(instance: int):
    if not valid_instance(instance):
        flash("VM không hợp lệ.", "error")
        return redirect(url_for("index"))

    mac = request.form.get("mac", "").strip()

    if not valid_mac(mac):
        flash("Địa chỉ MAC không hợp lệ.", "error")
        return redirect(
            url_for("vm_detail", instance=instance)
        )

    success, output = run_command(
        [
            str(SET_RESERVATION_SCRIPT),
            str(instance),
            mac,
        ],
        timeout=45,
    )

    flash(
        (
            f"Đã gán MAC cho VM{instance}."
            if success
            else output or "Không thể gán MAC."
        ),
        "success" if success else "error",
    )

    return redirect(
        url_for("vm_detail", instance=instance)
    )


@app.post("/vm/<int:instance>/proxy")
def change_proxy(instance: int):
    if not valid_instance(instance):
        flash("VM không hợp lệ.", "error")
        return redirect(url_for("index"))

    proxy_ip = request.form.get(
        "proxy_ip",
        "",
    ).strip()
    proxy_port = request.form.get(
        "proxy_port",
        "",
    ).strip()
    username = request.form.get(
        "username",
        "",
    ).strip()
    password = request.form.get(
        "password",
        "",
    )

    try:
        ipaddress.ip_address(proxy_ip)
    except ValueError:
        flash("Địa chỉ proxy không hợp lệ.", "error")
        return redirect(
            url_for("vm_detail", instance=instance)
        )

    if (
        not proxy_port.isdigit()
        or not 1 <= int(proxy_port) <= 65535
    ):
        flash("Port proxy không hợp lệ.", "error")
        return redirect(
            url_for("vm_detail", instance=instance)
        )

    if not username or not password:
        flash(
            "Username và password không được để trống.",
            "error",
        )
        return redirect(
            url_for("vm_detail", instance=instance)
        )

    success, output = run_command(
        [
            str(CHANGE_PROXY_SCRIPT),
            str(instance),
            proxy_ip,
            proxy_port,
            username,
            password,
        ],
        timeout=60,
    )

    flash(
        (
            f"Đã thay proxy cho VM{instance}."
            if success
            else output or "Không thể thay proxy."
        ),
        "success" if success else "error",
    )

    return redirect(
        url_for("vm_detail", instance=instance)
    )


@app.post("/vm/<int:instance>/service/<action>")
def service_action(instance: int, action: str):
    if not valid_instance(instance):
        flash("VM không hợp lệ.", "error")
        return redirect(url_for("index"))

    if action not in {"start", "stop", "restart"}:
        flash("Thao tác không hợp lệ.", "error")
        return redirect(
            url_for("vm_detail", instance=instance)
        )

    success, output = run_command(
        [
            "systemctl",
            action,
            service_name(instance),
        ],
        timeout=30,
    )

    flash(
        (
            f"Đã {action} tunnel VM{instance}."
            if success
            else output or "Không thể điều khiển service."
        ),
        "success" if success else "error",
    )

    return redirect(
        url_for("vm_detail", instance=instance)
    )


@app.route("/health")
def health():
    return {"status": "ok"}
