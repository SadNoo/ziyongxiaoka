#!/usr/bin/python3
"""Switch the Debian device between device-uplink and macOS host-uplink.

Only two fixed modes are accepted. Pairing material is read from a root-only
file and is never returned by status output or written to logs.
"""

from __future__ import annotations

import argparse
import fcntl
import ipaddress
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


STATE_DIR = Path(os.environ.get("WANGKA_STATE_DIR", "/var/lib/wangka-management"))
STATE_FILE = STATE_DIR / "state.json"
LOCK_FILE = STATE_DIR / "state.lock"
OPERATION_LOCK_FILE = STATE_DIR / "uplink-operation.lock"
PAIRING_FILE = Path(
    os.environ.get("WANGKA_HOST_UPLINK_CONFIG", "/etc/wangka/host-uplink.json")
)
HOST_FIREWALL = Path(
    os.environ.get(
        "WANGKA_HOST_UPLINK_FIREWALL", "/etc/nftables.d/wangka-host-uplink.nft"
    )
)
USB_CONNECTION = "usb"
USB_INTERFACE = "usb0"
HOTSPOT_CONNECTION = "hotspot"
MODEM_CLI = os.environ.get("WANGKA_MODEM_CLI", "/usr/local/sbin/wangka-modem")
UPTIME_PATH = Path(os.environ.get("WANGKA_UPTIME_PATH", "/proc/uptime"))
WLAN_OPERSTATE_PATH = Path(
    os.environ.get("WANGKA_WLAN_OPERSTATE", "/sys/class/net/wlan0/operstate")
)
DEVICE_ADDRESS = "192.168.5.1"
EXPECTED_HOST = "192.168.5.242"
EXPECTED_PORT = 19531
HOST_ROUTE_METRIC = 50
MAX_CONSECUTIVE_RENEW_FAILURES = 2
MIN_DEVICE_RECOVERY_UPTIME_SECONDS = 180
RESOLV_CONF = Path(
    os.environ.get(
        "WANGKA_RESOLV_CONF", "/var/lib/wangka-network/resolv.conf"
    )
)
FALLBACK_DEVICE_DNS = ["114.114.114.114", "223.5.5.5"]
TOKEN_PATTERN = re.compile(r"^[a-f0-9]{64}$")
VALID_MODES = {"device-uplink", "host-uplink"}


class UplinkError(RuntimeError):
    pass


def default_state() -> dict[str, Any]:
    return {
        "initialized": False,
        "generation": 0,
        "uplink_mode": "device-uplink",
        "work_mode": "dual",
        "access_mode": "login-required",
    }


def load_state() -> dict[str, Any]:
    state = default_state()
    try:
        loaded = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            state.update(loaded)
    except (OSError, ValueError):
        pass
    if state.get("uplink_mode") not in VALID_MODES:
        state["uplink_mode"] = "device-uplink"
    return state


def save_state(state: dict[str, Any]) -> None:
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = STATE_DIR / f".state.uplink.{os.getpid()}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(state, stream, ensure_ascii=False, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, STATE_FILE)
        os.chmod(STATE_FILE, 0o600)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


class StateLock:
    def __enter__(self) -> "StateLock":
        STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.stream = LOCK_FILE.open("a+", encoding="ascii")
        os.chmod(LOCK_FILE, 0o600)
        fcntl.flock(self.stream.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, *_: Any) -> None:
        fcntl.flock(self.stream.fileno(), fcntl.LOCK_UN)
        self.stream.close()


class OperationLock:
    """Bound mutating uplink work to one helper process at a time."""

    def __init__(self) -> None:
        self.stream: Any = None
        self.acquired = False

    def __enter__(self) -> "OperationLock":
        STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.stream = OPERATION_LOCK_FILE.open("a+", encoding="ascii")
        os.chmod(OPERATION_LOCK_FILE, 0o600)
        try:
            fcntl.flock(
                self.stream.fileno(),
                fcntl.LOCK_EX | fcntl.LOCK_NB,
            )
            self.acquired = True
        except BlockingIOError:
            self.acquired = False
        return self

    def __exit__(self, *_: Any) -> None:
        if self.stream is None:
            return
        if self.acquired:
            fcntl.flock(self.stream.fileno(), fcntl.LOCK_UN)
        self.stream.close()
        self.stream = None


def run_command(
    args: list[str],
    *,
    input_text: Optional[str] = None,
    check: bool = True,
    timeout: float = 20,
) -> str:
    result = subprocess.run(
        args,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if check and result.returncode != 0:
        raise UplinkError(f"system command failed: {Path(args[0]).name}")
    return result.stdout.strip()


def validate_ipv4(value: Any, *, allow_host: bool = False) -> str:
    try:
        address = ipaddress.ip_address(str(value))
    except ValueError as exc:
        raise UplinkError("host helper returned an invalid IPv4 address") from exc
    if address.version != 4 or address.is_unspecified or address.is_loopback:
        raise UplinkError("host helper returned an invalid IPv4 address")
    result = str(address)
    if allow_host and result != EXPECTED_HOST:
        raise UplinkError("host helper address does not match the paired USB address")
    if (result.startswith("192.168.5.") or result == "192.168.4.1") and not allow_host:
        raise UplinkError("host helper returned a management address as DNS")
    return result


def load_pairing() -> dict[str, str]:
    try:
        raw = PAIRING_FILE.read_text(encoding="utf-8")
        config = json.loads(raw)
    except (OSError, ValueError) as exc:
        raise UplinkError("macOS host helper is not paired") from exc
    if not isinstance(config, dict):
        raise UplinkError("macOS host helper pairing file is invalid")
    helper_url = str(config.get("helper_url", ""))
    token = str(config.get("token", ""))
    parsed = urlsplit(helper_url)
    if (
        parsed.scheme != "http"
        or parsed.hostname != EXPECTED_HOST
        or parsed.port != EXPECTED_PORT
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
    ):
        raise UplinkError("macOS host helper URL is invalid")
    if not TOKEN_PATTERN.fullmatch(token):
        raise UplinkError("macOS host helper token is invalid")
    return {"helper_url": helper_url.rstrip("/"), "token": token}


def helper_request(action: str, *, timeout: float = 5.0) -> dict[str, Any]:
    if action not in {"status", "enable", "disable"}:
        raise UplinkError("invalid host helper action")
    pairing = load_pairing()
    method = "GET" if action == "status" else "POST"
    request = Request(
        f"{pairing['helper_url']}/v1/{action}",
        data=None if method == "GET" else b"{}",
        method=method,
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-Wangka-Token": pairing["token"],
        },
    )
    payload: Any = None
    for attempt in range(2):
        try:
            with urlopen(request, timeout=timeout) as response:
                if response.status != 200:
                    raise UplinkError("macOS host helper rejected the request")
                payload = json.loads(response.read(16 * 1024))
            break
        except HTTPError as exc:
            raise UplinkError("macOS host helper rejected the request") from exc
        except (URLError, TimeoutError, OSError) as exc:
            if attempt == 0:
                time.sleep(0.15)
                continue
            raise UplinkError("macOS host helper is unreachable") from exc
        except (ValueError, TypeError) as exc:
            raise UplinkError("macOS host helper returned invalid data") from exc
    if not isinstance(payload, dict) or payload.get("status") != "ok":
        raise UplinkError("macOS host helper returned an error")
    return payload


def validate_enable_response(payload: dict[str, Any]) -> tuple[str, list[str]]:
    if payload.get("enabled") is not True:
        raise UplinkError("macOS host helper did not enable forwarding")
    host = validate_ipv4(payload.get("host_address"), allow_host=True)
    raw_dns = payload.get("dns_servers")
    if not isinstance(raw_dns, list) or not 1 <= len(raw_dns) <= 3:
        raise UplinkError("macOS host helper returned no usable DNS servers")
    dns_servers: list[str] = []
    for value in raw_dns:
        address = validate_ipv4(value)
        if address not in dns_servers:
            dns_servers.append(address)
    if not dns_servers:
        raise UplinkError("macOS host helper returned no usable DNS servers")
    return host, dns_servers


def usb_management_ready() -> None:
    output = run_command(["/usr/sbin/ip", "-4", "-o", "addr", "show", "dev", USB_INTERFACE])
    if f" {DEVICE_ADDRESS}/24 " not in f" {output} ":
        raise UplinkError("USB management address is not ready")


def apply_host_network(host: str, dns_servers: list[str]) -> None:
    usb_management_ready()
    route_value = f"0.0.0.0/0 {host} {HOST_ROUTE_METRIC}"
    # Install the client-isolation guard before exposing a route through USB.
    if not host_guard_active():
        run_command(["/usr/sbin/nft", "-f", str(HOST_FIREWALL)])
    run_command(
        [
            "/usr/bin/nmcli",
            "connection",
            "modify",
            USB_CONNECTION,
            "ipv4.routes",
            route_value,
            "ipv4.never-default",
            "no",
        ]
    )
    write_resolv_conf(dns_servers, "macOS host-uplink")
    run_command(["/usr/bin/nmcli", "device", "reapply", USB_INTERFACE])
    run_command(
        [
            "/usr/sbin/ip",
            "route",
            "replace",
            "default",
            "via",
            host,
            "dev",
            USB_INTERFACE,
            "metric",
            str(HOST_ROUTE_METRIC),
        ]
    )


def host_guard_active() -> bool:
    result = subprocess.run(
        ["/usr/sbin/nft", "list", "table", "inet", "wangka_host_uplink"],
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=10,
        check=False,
    )
    return result.returncode == 0


def clear_host_network() -> None:
    dns_servers = device_mode_dns()
    run_command(
        [
            "/usr/bin/nmcli",
            "connection",
            "modify",
            USB_CONNECTION,
            "ipv4.routes",
            "",
            "ipv4.never-default",
            "yes",
        ],
        check=False,
    )
    write_resolv_conf(dns_servers, "device-uplink")
    run_command(["/usr/bin/nmcli", "device", "reapply", USB_INTERFACE], check=False)
    run_command(
        [
            "/usr/sbin/ip",
            "route",
            "del",
            "default",
            "via",
            EXPECTED_HOST,
            "dev",
            USB_INTERFACE,
            "metric",
            str(HOST_ROUTE_METRIC),
        ],
        check=False,
    )
    run_command(
        ["/usr/sbin/nft", "delete", "table", "inet", "wangka_host_uplink"],
        check=False,
    )


def write_resolv_conf(servers: list[str], source: str) -> None:
    validated = [validate_ipv4(value) for value in servers]
    if not validated:
        raise UplinkError("no DNS servers available")
    RESOLV_CONF.parent.mkdir(parents=True, exist_ok=True)
    temporary = RESOLV_CONF.parent / f".resolv.conf.wangka.{os.getpid()}"
    content = [f"# Managed by wangka-uplink ({source})."]
    content.extend(f"nameserver {server}" for server in validated)
    content.extend(["options timeout:2 attempts:2", ""])
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        with os.fdopen(fd, "w", encoding="ascii") as stream:
            stream.write("\n".join(content))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, RESOLV_CONF)
        os.chmod(RESOLV_CONF, 0o644)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def device_mode_dns() -> list[str]:
    output = run_command(
        ["/usr/bin/nmcli", "-t", "-f", "IP4.DNS", "device", "show"], check=False
    )
    servers: list[str] = []
    for line in output.splitlines():
        _, _, value = line.partition(":")
        try:
            address = validate_ipv4(value)
        except UplinkError:
            continue
        if address not in servers:
            servers.append(address)
    return servers[:3] or list(FALLBACK_DEVICE_DNS)


def connection_is_active(name: str) -> bool:
    output = run_command(
        ["/usr/bin/nmcli", "-t", "-f", "NAME", "connection", "show", "--active"],
        check=False,
    )
    return name in output.splitlines()


def hotspot_interface_active() -> bool:
    try:
        return WLAN_OPERSTATE_PATH.read_text(encoding="ascii").strip() == "up"
    except OSError:
        return False


def recover_hotspot() -> bool:
    """Best-effort Wi-Fi recovery without blocking USB, VoHive or LTE."""
    # Reading sysfs is effectively free. Starting nmcli every 30 seconds on
    # this small CPU consumed several seconds of CPU per timer cycle even
    # while the hotspot was already healthy.
    if hotspot_interface_active():
        return True
    run_command(
        [
            "/usr/bin/nmcli",
            "--wait",
            "10",
            "connection",
            "up",
            HOTSPOT_CONNECTION,
        ],
        check=False,
    )
    return hotspot_interface_active() or connection_is_active(HOTSPOT_CONNECTION)


def resolver_ready() -> bool:
    try:
        if RESOLV_CONF.stat().st_size > 16 * 1024:
            return False
        content = RESOLV_CONF.read_text(encoding="ascii")
    except (OSError, UnicodeError):
        return False
    for line in content.splitlines():
        key, _, value = line.partition(" ")
        if key != "nameserver":
            continue
        try:
            validate_ipv4(value.strip())
            return True
        except UplinkError:
            continue
    return False


def wwan_default_ready() -> bool:
    output = run_command(
        ["/usr/sbin/ip", "-4", "route", "show", "default"], check=False
    )
    return any(" dev wwan0 " in f" {line} " for line in output.splitlines())


def device_uptime_seconds() -> float:
    try:
        return float(UPTIME_PATH.read_text(encoding="ascii").split()[0])
    except (OSError, ValueError, IndexError):
        # An unknown uptime must fail closed: never cycle packet data during
        # an indeterminate boot phase.
        return 0.0


def recover_device_uplink() -> bool:
    """Restore a previously enabled LTE route through the VoHive owner."""
    if wwan_default_ready():
        return True
    # The onboard modem performs one intentional remoteproc reset and a cold
    # QMI warm-up during normal boot. VoHive then restores packet data itself.
    # Intervening before that sequence completes can extend USB/QMI downtime.
    if device_uptime_seconds() < MIN_DEVICE_RECOVERY_UPTIME_SECONDS:
        return False
    run_command(
        [MODEM_CLI, "reconnect-saved-uplink"],
        check=False,
        timeout=110,
    )
    return wwan_default_ready()


def update_result(
    state: dict[str, Any], mode: str, result: str, error: str = ""
) -> dict[str, Any]:
    state["uplink_mode"] = mode
    state["uplink_last_result"] = result
    state["uplink_last_error"] = error[:240]
    state["uplink_changed_at"] = int(time.time())
    save_state(state)
    return state


def switch_host() -> dict[str, Any]:
    previous = load_state()
    try:
        helper_status = helper_request("enable")
        host, dns_servers = validate_enable_response(helper_status)
        apply_host_network(host, dns_servers)
        previous["uplink_renew_failures"] = 0
        previous["uplink_lease_deadline_epoch"] = int(
            helper_status.get("lease_deadline_epoch", 0)
        )
        state = update_result(previous, "host-uplink", "ok")
        return {"status": "ok", "mode": state["uplink_mode"], "helper": sanitize_helper(helper_status)}
    except (UplinkError, OSError, subprocess.TimeoutExpired) as exc:
        cleanup_error = ""
        try:
            clear_host_network()
        except (UplinkError, OSError, subprocess.TimeoutExpired) as cleanup_exc:
            cleanup_error = f"; device cleanup warning: {cleanup_exc}"
        try:
            helper_request("disable")
        except UplinkError:
            pass
        detail = f"{exc}{cleanup_error}"
        update_result(previous, "device-uplink", "rolled-back", detail)
        raise UplinkError(f"host-uplink failed and was rolled back: {detail}") from exc


def switch_device() -> dict[str, Any]:
    state = load_state()
    warning = ""
    try:
        clear_host_network()
    except (UplinkError, OSError, subprocess.TimeoutExpired) as exc:
        warning = f"device cleanup warning: {exc}"
    try:
        helper_request("disable")
    except UplinkError as exc:
        # The Mac helper lease removes its private PF anchor automatically.
        prefix = f"{warning}; " if warning else ""
        warning = f"{prefix}{exc}; macOS state will expire automatically"
    update_result(state, "device-uplink", "ok" if not warning else "cleanup-pending", warning)
    return {"status": "ok", "mode": "device-uplink", "warning": warning}


def sanitize_helper(payload: dict[str, Any]) -> dict[str, Any]:
    allowed = {
        "enabled",
        "usb_interface",
        "host_address",
        "upstream_interface",
        "dns_servers",
        "lease_deadline_epoch",
        "last_error",
    }
    return {key: value for key, value in payload.items() if key in allowed}


def status() -> dict[str, Any]:
    state = load_state()
    response: dict[str, Any] = {
        "status": "ok",
        "mode": state.get("uplink_mode", "device-uplink"),
        "installed": PAIRING_FILE.is_file(),
        "helper_reachable": False,
        "helper_enabled": False,
        "last_result": state.get("uplink_last_result", "never"),
        "last_error": state.get("uplink_last_error", ""),
        "changed_at": state.get("uplink_changed_at", 0),
    }
    if not PAIRING_FILE.is_file():
        return response
    if response["mode"] != "host-uplink":
        # Do not contact the Mac helper on every device status refresh while
        # the device owns its uplink. A missing Mac used to add seconds of
        # latency and could queue status helpers behind a mode transition.
        response["helper_checked"] = False
        return response
    try:
        helper = helper_request("status", timeout=3.0)
        response["helper_checked"] = True
        response["helper_reachable"] = True
        response["helper_enabled"] = helper.get("enabled") is True
        response["helper"] = sanitize_helper(helper)
    except UplinkError as exc:
        response["helper_error"] = str(exc)
    return response


def reconcile() -> dict[str, Any]:
    hotspot_active = recover_hotspot()
    state = load_state()
    if state.get("uplink_mode") != "host-uplink":
        # SMS-only mode deliberately keeps packet data down.  Do not let the
        # periodic uplink recovery undo the selected work mode after boot.
        sms_only = state.get("work_mode") == "sms"
        device_uplink_active = False if sms_only else recover_device_uplink()
        # LTE may register after boot.  Keep the resolver synchronized with
        # the active device uplink and retain the domestic fallback when the
        # carrier exposes no usable IPv4 DNS. A healthy resolver is left
        # untouched so steady-state reconciliation never starts nmcli.
        resolver_refreshed = False
        if not resolver_ready():
            write_resolv_conf(device_mode_dns(), "device-uplink")
            resolver_refreshed = True
        result = status()
        result["hotspot_active"] = hotspot_active
        result["device_uplink_active"] = device_uplink_active
        result["resolver_refreshed"] = resolver_refreshed
        result["work_mode"] = state.get("work_mode", "dual")
        return result
    try:
        helper_status = helper_request("enable")
        host, dns_servers = validate_enable_response(helper_status)
        apply_host_network(host, dns_servers)
        state["uplink_renew_failures"] = 0
        state["uplink_lease_deadline_epoch"] = int(
            helper_status.get("lease_deadline_epoch", 0)
        )
        state["uplink_last_result"] = "renewed"
        state["uplink_last_error"] = ""
        save_state(state)
        return {
            "status": "ok",
            "mode": "host-uplink",
            "hotspot_active": hotspot_active,
            "helper": sanitize_helper(helper_status),
        }
    except (UplinkError, OSError, subprocess.TimeoutExpired) as exc:
        failures = int(state.get("uplink_renew_failures", 0)) + 1
        if failures < MAX_CONSECUTIVE_RENEW_FAILURES:
            state["uplink_renew_failures"] = failures
            state["uplink_last_result"] = "renew-warning"
            state["uplink_last_error"] = str(exc)[:240]
            save_state(state)
            return {
                "status": "ok",
                "mode": "host-uplink",
                "hotspot_active": hotspot_active,
                "warning": "temporary host helper timeout; retry scheduled",
                "renew_failures": failures,
            }
        cleanup_error = ""
        try:
            clear_host_network()
        except (UplinkError, OSError, subprocess.TimeoutExpired) as cleanup_exc:
            cleanup_error = f"; device cleanup warning: {cleanup_exc}"
        try:
            helper_request("disable")
        except UplinkError:
            pass
        detail = f"{exc}{cleanup_error}"
        update_result(state, "device-uplink", "rolled-back", detail)
        raise UplinkError(f"host-uplink health check failed; device mode restored: {detail}") from exc


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["status", "host-uplink", "device-uplink", "reconcile"])
    args = parser.parse_args()
    try:
        if args.action == "status":
            # State writes are atomic, so this read-only path must not wait
            # behind slow modem or NetworkManager operations.
            result = status()
        else:
            with OperationLock() as operation:
                if not operation.acquired:
                    if args.action == "reconcile":
                        result = status()
                        result["reconcile_skipped"] = "uplink-operation-in-progress"
                    else:
                        raise UplinkError("another uplink operation is already running")
                else:
                    with StateLock():
                        if args.action == "host-uplink":
                            result = switch_host()
                        elif args.action == "device-uplink":
                            result = switch_device()
                        else:
                            result = reconcile()
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0
    except (UplinkError, OSError, subprocess.TimeoutExpired) as exc:
        print(json.dumps({"status": "error", "message": str(exc)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
