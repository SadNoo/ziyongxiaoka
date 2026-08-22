#!/usr/bin/python3
"""Local CLI for the VoHive-owned onboard modem.

Authentication stays on loopback and the session token is never printed.
ModemManager is intentionally not used because VoHive is the single QMI
owner on this hardware.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


CONFIG_PATH = "/etc/vohive/config.yaml"
CREDENTIAL_PATH = Path("/var/lib/wangka-management/vohive-local-auth.json")
NETWORK_PREFERENCE_PATH = Path(
    os.environ.get(
        "WANGKA_MODEM_NETWORK_PREFERENCE",
        "/var/lib/wangka-management/modem-network.json",
    )
)
BASE_URL = "http://127.0.0.1:17575"
DEVICE_ID = "onboard-qmi"
MAX_CREDENTIAL_BYTES = 16 * 1024
MAX_NETWORK_PREFERENCE_BYTES = 4 * 1024


class CLIError(RuntimeError):
    pass


def decode_yaml_scalar(value: str) -> str:
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        return json.loads(value)
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1].replace("''", "'")
    return value.split(" #", 1)[0].strip()


def config_scalar(text: str, key: str) -> str:
    web = re.search(r"(?m)^web:[ \t]*(.*)$", text)
    if not web:
        raise CLIError("missing VoHive web config")

    inline = web.group(1).lstrip()
    if inline.startswith("{"):
        # VoHive rewrites its config as a YAML flow mapping after the first
        # settings update. Quoted values may contain commas or colons.
        value_pattern = (
            r'"(?:\\.|[^"\\])*"'
            r"|'(?:''|[^'])*'"
            r"|[^,}\n#]+"
        )
        match = re.search(
            rf"(?:^|[,{{])\s*{re.escape(key)}\s*:\s*({value_pattern})",
            inline,
        )
    else:
        following = text[web.end() :]
        next_section = re.search(r"(?m)^[A-Za-z0-9_-]+:\s*", following)
        section = following[: next_section.start()] if next_section else following
        match = re.search(
            rf"(?m)^[ \t]+{re.escape(key)}:\s*(.+?)\s*$", section
        )
    if not match:
        raise CLIError(f"missing VoHive credential field: {key}")
    return decode_yaml_scalar(match.group(1))


def request_json(
    method: str,
    path: str,
    *,
    token: str | None = None,
    payload: dict[str, Any] | None = None,
    timeout: float = 60.0,
) -> Any:
    body = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(
        BASE_URL + path, data=body, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        raise CLIError(f"VoHive API returned HTTP {exc.code}") from exc
    except (OSError, ValueError, urllib.error.URLError) as exc:
        raise CLIError("VoHive API is unavailable") from exc


def save_credentials(
    username: str, password: str, path: Path | None = None
) -> None:
    path = CREDENTIAL_PATH if path is None else path
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temporary = path.parent / f".{path.name}.{os.getpid()}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(
                {"username": username, "password": password},
                stream,
                ensure_ascii=False,
                sort_keys=True,
            )
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def stored_credentials(path: Path = CREDENTIAL_PATH) -> tuple[str, str]:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    with os.fdopen(fd, "r", encoding="utf-8") as stream:
        info = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or stat.S_IMODE(info.st_mode) & 0o077
            or info.st_size > MAX_CREDENTIAL_BYTES
        ):
            raise CLIError("invalid local VoHive credential store")
        try:
            loaded = json.load(stream)
        except (ValueError, UnicodeError) as exc:
            raise CLIError("invalid local VoHive credential store") from exc
    if not isinstance(loaded, dict):
        raise CLIError("invalid local VoHive credential store")
    username = str(loaded.get("username", ""))
    password = str(loaded.get("password", ""))
    if username != "user" or not password:
        raise CLIError("invalid local VoHive credential store")
    return username, password


def save_network_preference(
    enabled: bool,
    apn: str = "",
    ip_version: str = "v4v6",
    path: Path | None = None,
) -> None:
    path = NETWORK_PREFERENCE_PATH if path is None else path
    if enabled and not re.fullmatch(r"[A-Za-z0-9.-]{1,100}", apn):
        raise CLIError("APN contains unsupported characters")
    if ip_version not in {"v4", "v6", "v4v6"}:
        raise CLIError("unsupported IP version")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temporary = path.parent / f".{path.name}.{os.getpid()}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(
                {"apn": apn, "enabled": enabled, "ip_version": ip_version},
                stream,
                ensure_ascii=False,
                sort_keys=True,
            )
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def load_network_preference(
    path: Path | None = None,
) -> dict[str, str | bool]:
    path = NETWORK_PREFERENCE_PATH if path is None else path
    try:
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(path, flags)
    except FileNotFoundError:
        return {"enabled": False, "apn": "", "ip_version": "v4v6"}
    with os.fdopen(fd, "r", encoding="utf-8") as stream:
        info = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or stat.S_IMODE(info.st_mode) & 0o077
            or info.st_size > MAX_NETWORK_PREFERENCE_BYTES
        ):
            raise CLIError("invalid modem network preference")
        try:
            loaded = json.load(stream)
        except (ValueError, UnicodeError) as exc:
            raise CLIError("invalid modem network preference") from exc
    if not isinstance(loaded, dict):
        raise CLIError("invalid modem network preference")
    enabled = loaded.get("enabled") is True
    apn = str(loaded.get("apn", ""))
    ip_version = str(loaded.get("ip_version", "v4v6"))
    if enabled and not re.fullmatch(r"[A-Za-z0-9.-]{1,100}", apn):
        raise CLIError("invalid modem network preference")
    if ip_version not in {"v4", "v6", "v4v6"}:
        raise CLIError("invalid modem network preference")
    return {"enabled": enabled, "apn": apn, "ip_version": ip_version}


def config_credentials() -> tuple[str, str]:
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as stream:
            text = stream.read(1024 * 1024)
    except OSError as exc:
        raise CLIError("cannot read VoHive config") from exc
    return config_scalar(text, "username"), config_scalar(text, "password")


def login_with_credentials(username: str, password: str) -> str:
    result = request_json(
        "POST",
        "/api/auth/login",
        payload={"username": username, "password": password},
        timeout=15.0,
    )
    token = str(result.get("token", "")) if isinstance(result, dict) else ""
    if not token:
        raise CLIError("VoHive login failed")
    return token


def login() -> str:
    try:
        username, password = stored_credentials()
    except FileNotFoundError:
        username, password = config_credentials()
        token = login_with_credentials(username, password)
        save_credentials(username, password)
        return token
    return login_with_credentials(username, password)


def bootstrap_password(path: Path) -> str:
    try:
        if path.stat().st_size > MAX_CREDENTIAL_BYTES:
            raise CLIError("bootstrap credential file is unexpectedly large")
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise CLIError("cannot read bootstrap credential file") from exc
    match = re.search(r"(?m)^WANGKA_USER_PASSWORD='([^'\n]*)'$", text)
    if not match or not match.group(1):
        raise CLIError("bootstrap credential file is invalid")
    return match.group(1)


def command_credential_bootstrap(_: str, args: argparse.Namespace) -> None:
    password = bootstrap_password(Path(args.path))
    login_with_credentials("user", password)
    save_credentials("user", password)
    print_json({"status": "ok"})


def device_overview(token: str) -> dict[str, Any]:
    result = request_json(
        "GET", f"/api/devices/{DEVICE_ID}/overview", token=token, timeout=30.0
    )
    devices = result.get("devices", []) if isinstance(result, dict) else []
    if len(devices) != 1 or not isinstance(devices[0], dict):
        raise CLIError("onboard modem is unavailable")
    return devices[0]


def print_json(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))


def command_list(token: str, _: argparse.Namespace) -> None:
    item = device_overview(token)
    print_json(
        {
            "id": item.get("id", DEVICE_ID),
            "name": item.get("name", ""),
            "running": bool(item.get("running")),
            "healthy": bool(item.get("healthy")),
            "backend_mode": item.get("backend_mode", ""),
        }
    )


def command_status(token: str, _: argparse.Namespace) -> None:
    item = device_overview(token)
    modem = item.get("modem") if isinstance(item.get("modem"), dict) else {}
    print_json(
        {
            "running": bool(item.get("running")),
            "healthy": bool(item.get("healthy")),
            "control_online": bool(item.get("control_online")),
            "radio_registered": bool(item.get("radio_registered")),
            "network_connected": bool(item.get("network_connected")),
            "backend_mode": item.get("backend_mode", ""),
            "operator": modem.get("operator", ""),
            "network_mode": modem.get("network_mode", ""),
            "signal_dbm": modem.get("signal_dbm"),
        }
    )


def command_sim(token: str, _: argparse.Namespace) -> None:
    item = device_overview(token)
    modem = item.get("modem") if isinstance(item.get("modem"), dict) else {}
    print_json(
        {
            "sim_present": bool(modem.get("iccid") or modem.get("imsi")),
            "identity_ready": bool(modem.get("imsi")),
            "radio_registered": bool(item.get("radio_registered")),
            "operator": modem.get("operator", ""),
            "local_phone_known": bool(item.get("local_phone")),
        }
    )


def command_sms_list(token: str, args: argparse.Namespace) -> None:
    query = urllib.parse.urlencode({"limit": args.limit, "device_id": DEVICE_ID})
    print_json(request_json("GET", f"/api/sms/contacts?{query}", token=token))


def command_sms_read(token: str, args: argparse.Namespace) -> None:
    query = urllib.parse.urlencode(
        {"limit": args.limit, "device_id": DEVICE_ID, "peer": args.peer}
    )
    print_json(request_json("GET", f"/api/sms/thread?{query}", token=token))


def command_sms_delete(token: str, args: argparse.Namespace) -> None:
    result = request_json(
        "DELETE", f"/api/sms/messages/{args.message_id}", token=token
    )
    print_json({"status": result.get("status", "ok")})


def command_sms_send(token: str, args: argparse.Namespace) -> None:
    result = request_json(
        "POST",
        "/api/sms/send",
        token=token,
        payload={
            "device_id": DEVICE_ID,
            "phone": args.number,
            "message": " ".join(args.text),
            "encoding": args.encoding,
        },
        timeout=180.0,
    )
    print_json(
        {
            "status": result.get("status", ""),
            "message": result.get("message", ""),
            "parts_total": result.get("parts_total", 1),
        }
    )


def command_pin(token: str, args: argparse.Namespace) -> None:
    if not re.fullmatch(r"[0-9]{4,8}", args.pin):
        raise CLIError("PIN must contain 4 to 8 digits")
    result = request_json(
        "POST",
        f"/api/devices/{DEVICE_ID}/actions/at",
        token=token,
        payload={"cmd": f'AT+CPIN="{args.pin}"', "timeout_ms": 10000},
        timeout=20.0,
    )
    print_json({"status": result.get("status", "")})


def command_data_connect(token: str, args: argparse.Namespace) -> None:
    if not re.fullmatch(r"[A-Za-z0-9.-]{1,100}", args.apn):
        raise CLIError("APN contains unsupported characters")
    save_network_preference(True, args.apn, args.ip_version)
    result = request_json(
        "PATCH",
        f"/api/devices/{DEVICE_ID}/network",
        token=token,
        payload={"enabled": True, "ip_version": args.ip_version, "apn": args.apn},
        timeout=90.0,
    )
    print_json(
        {
            "status": result.get("status", ""),
            "message": result.get("message", ""),
            "network_connected": bool(result.get("network_connected")),
        }
    )


def command_data_disconnect(token: str, _: argparse.Namespace) -> None:
    save_network_preference(False)
    result = request_json(
        "PATCH",
        f"/api/devices/{DEVICE_ID}/network",
        token=token,
        payload={"enabled": False},
        timeout=60.0,
    )
    print_json(
        {
            "status": result.get("status", ""),
            "message": result.get("message", ""),
            "network_connected": bool(result.get("network_connected")),
        }
    )


def command_data_suspend(token: str, _: argparse.Namespace) -> None:
    """Stop packet data without erasing the saved APN preference."""
    result = request_json(
        "PATCH",
        f"/api/devices/{DEVICE_ID}/network",
        token=token,
        payload={"enabled": False},
        timeout=60.0,
    )
    print_json(
        {
            "status": result.get("status", "ok"),
            "message": result.get("message", ""),
            "network_connected": bool(result.get("network_connected")),
        }
    )


def command_reconnect(token: str, _: argparse.Namespace) -> None:
    preference = load_network_preference()
    if preference["enabled"] is not True:
        print_json({"status": "skipped", "reason": "data-uplink-disabled"})
        return
    item = device_overview(token)
    if not (
        item.get("running")
        and item.get("healthy")
        and item.get("radio_registered")
    ):
        print_json({"status": "skipped", "reason": "radio-not-ready"})
        return
    # VoHive treats an already-connected PATCH as a no-op, even if the Linux
    # route disappeared after a reboot or interface event. The caller only
    # reaches this hidden recovery action when no wwan0 default route exists,
    # so cycle packet data and let VoHive reapply the address and routes.
    request_json(
        "PATCH",
        f"/api/devices/{DEVICE_ID}/network",
        token=token,
        payload={"enabled": False},
        timeout=60.0,
    )
    result = request_json(
        "PATCH",
        f"/api/devices/{DEVICE_ID}/network",
        token=token,
        payload={
            "enabled": True,
            "ip_version": preference["ip_version"],
            "apn": preference["apn"],
        },
        timeout=90.0,
    )
    print_json(
        {
            "status": result.get("status", ""),
            "network_connected": bool(result.get("network_connected")),
        }
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="wangka-modem")
    subparsers = parser.add_subparsers(dest="command", required=True)

    for name, handler in (
        ("list", command_list),
        ("status", command_status),
        ("sim", command_sim),
    ):
        command = subparsers.add_parser(name)
        command.set_defaults(handler=handler)

    sms_list = subparsers.add_parser("sms-list")
    sms_list.add_argument("--limit", type=int, default=50)
    sms_list.set_defaults(handler=command_sms_list)

    sms_read = subparsers.add_parser("sms-read")
    sms_read.add_argument("peer")
    sms_read.add_argument("--limit", type=int, default=50)
    sms_read.set_defaults(handler=command_sms_read)

    sms_delete = subparsers.add_parser("sms-delete")
    sms_delete.add_argument("message_id", type=int)
    sms_delete.set_defaults(handler=command_sms_delete)

    sms_send = subparsers.add_parser("sms-send")
    sms_send.add_argument("number")
    sms_send.add_argument("text", nargs="+")
    sms_send.add_argument("--encoding", choices=("auto", "gsm7", "ucs2"), default="auto")
    sms_send.set_defaults(handler=command_sms_send)

    pin = subparsers.add_parser("pin")
    pin.add_argument("pin")
    pin.set_defaults(handler=command_pin)

    connect = subparsers.add_parser("data-connect")
    connect.add_argument("apn")
    connect.add_argument("--ip-version", choices=("v4", "v6", "v4v6"), default="v4v6")
    connect.set_defaults(handler=command_data_connect)

    disconnect = subparsers.add_parser("data-disconnect")
    disconnect.set_defaults(handler=command_data_disconnect)

    return parser


def main() -> int:
    hidden_control_action = (
        len(sys.argv) == 2
        and sys.argv[1] in {"data-suspend", "reconnect-saved-uplink"}
    )
    try:
        # Deployment-only bootstrap stays out of the public command list. It
        # verifies the supplied password against loopback before persisting it.
        if len(sys.argv) == 3 and sys.argv[1] == "credential-bootstrap-file":
            command_credential_bootstrap("", argparse.Namespace(path=sys.argv[2]))
        elif len(sys.argv) == 2 and sys.argv[1] == "data-suspend":
            command_data_suspend(login(), argparse.Namespace())
        elif len(sys.argv) == 2 and sys.argv[1] == "reconnect-saved-uplink":
            command_reconnect(login(), argparse.Namespace())
        else:
            args = build_parser().parse_args()
            args.handler(login(), args)
    except CLIError as exc:
        if hidden_control_action:
            # Work-mode consumes a strict JSON protocol. Returning structured
            # errors avoids the misleading "invalid result" produced by an
            # empty stdout stream when the local VoHive API is unavailable.
            print_json({"status": "error", "message": str(exc)[:240]})
        else:
            print(f"wangka-modem: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
