#!/usr/bin/python3
"""Enroll the single onboard QMI modem into a fresh VoHive installation.

The device identity is discovered locally and never printed.  The script is
idempotent and refuses to guess when discovery returns zero, degraded, or
multiple devices.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request


CONFIG_PATH = "/etc/vohive/config.yaml"
BASE_URL = "http://127.0.0.1:17575"


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
        raise RuntimeError("missing Web config")

    inline = web.group(1).lstrip()
    if inline.startswith("{"):
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
        raise RuntimeError(f"missing Web credential field: {key}")
    return decode_yaml_scalar(match.group(1))


def request_json(
    method: str,
    path: str,
    *,
    token: str | None = None,
    payload: dict | None = None,
    timeout: float = 15.0,
) -> dict:
    body = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(
        BASE_URL + path, data=body, headers=headers, method=method
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)


def already_persisted(config_text: str) -> bool:
    # VoHive rewrites YAML using flow style, for example:
    # devices: [{id: onboard-qmi, ...}]
    return bool(re.search(r"\bid:\s*onboard-qmi(?:\s|,|})", config_text))


def enroll_once() -> bool:
    with open(CONFIG_PATH, "r", encoding="utf-8") as config_file:
        config_text = config_file.read()

    if already_persisted(config_text):
        print("VoHive onboard modem is already enrolled")
        return True

    username = config_scalar(config_text, "username")
    password = config_scalar(config_text, "password")
    login = request_json(
        "POST", "/api/auth/login", payload={"username": username, "password": password}
    )
    token = login.get("token", "")
    if not token:
        raise RuntimeError("local VoHive login did not return a session token")

    discovery = request_json(
        "GET", "/api/devices/discovered?with_imei=1", token=token, timeout=30.0
    )
    devices = discovery.get("devices") or []
    if len(devices) != 1:
        raise RuntimeError(f"expected exactly one onboard modem; discovered {len(devices)}")

    modem = devices[0]
    if modem.get("configured"):
        print("VoHive onboard modem is already configured")
        return True
    if modem.get("degraded"):
        raise RuntimeError("onboard modem discovery is degraded")
    if not modem.get("imei"):
        raise RuntimeError("onboard modem stable identity is not ready")
    if modem.get("mode") != "qmi" or not modem.get("network_capable"):
        raise RuntimeError("onboard modem is not a network-capable QMI device")

    at_ports = modem.get("at_ports") or []
    at_port = modem.get("at_port") or (at_ports[0] if at_ports else "")
    proxy_executable = "/usr/libexec/qmi-proxy"
    if not os.path.exists(proxy_executable):
        proxy_executable = "/usr/bin/qmi-proxy"

    payload = {
        "config": {
            "id": "onboard-qmi",
            "name": "板载高通调制解调器",
            "modem_imei": modem["imei"],
            "usb_path": modem.get("usb_path", ""),
            "at_port": at_port,
            "interface": modem.get("net_interface", ""),
            "control_device": modem.get("control_path", ""),
            "qmi_use_proxy": True,
            "qmi_proxy_executable": proxy_executable,
            "esim_transport": "at",
            "device_backend": "qmi",
            "sms_enabled": True,
            "network_enabled": False,
            "vowifi_enabled": False,
        }
    }
    result = request_json("POST", "/api/devices", token=token, payload=payload, timeout=45.0)
    if result.get("status") != "ok":
        raise RuntimeError("VoHive rejected onboard modem enrollment")
    print("VoHive onboard QMI modem enrollment completed")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    deadline = time.monotonic() + max(args.timeout, 1)
    last_error = "not attempted"
    while time.monotonic() < deadline:
        try:
            if enroll_once():
                return 0
        except (OSError, ValueError, RuntimeError, urllib.error.URLError) as exc:
            # Do not print response bodies or hardware identities.
            last_error = str(exc).splitlines()[0][:240]
        time.sleep(5)

    print(f"VoHive onboard modem enrollment timed out: {last_error}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
