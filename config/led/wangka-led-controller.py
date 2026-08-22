#!/usr/bin/python3
"""Drive the UFI103S RGB status LED from appliance state.

The board exposes three binary GPIO LED channels.  Steady colours and kernel
timer triggers are used so blinking does not consume CPU on the MSM8916.  The
daemon only reads the atomic management state and thermal sysfs; it never
talks to the modem or competes for QMI ownership.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import threading
from pathlib import Path
from typing import Any


STATE_DIR = Path(os.environ.get("WANGKA_STATE_DIR", "/var/lib/wangka-management"))
STATE_FILE = STATE_DIR / "state.json"
RUNTIME_FILE = Path(os.environ.get("WANGKA_LED_RUNTIME", "/run/wangka-led/status.json"))
THERMAL_ROOT = Path(os.environ.get("WANGKA_THERMAL_ROOT", "/sys/class/thermal"))
LED_ROOT = Path(os.environ.get("WANGKA_LED_ROOT", "/sys/class/leds"))
BACKEND_HOST = os.environ.get("WANGKA_VOHIVE_HOST", "127.0.0.1")
BACKEND_PORT = int(os.environ.get("WANGKA_VOHIVE_PORT", "17575"))
POLL_SECONDS = float(os.environ.get("WANGKA_LED_POLL_SECONDS", "2"))
THERMAL_WARNING_C = 85.0
THERMAL_CRITICAL_C = 92.0

LED_NAMES = {
    "red": "red:power",
    "green": "green:wlan",
    "blue": "blue:wan",
}
RGB = {
    "off": (),
    "red": ("red",),
    "green": ("green",),
    "blue": ("blue",),
    "yellow": ("red", "green"),
    "cyan": ("green", "blue"),
    "magenta": ("red", "blue"),
    "white": ("red", "green", "blue"),
}
COLOR_LABELS = {
    "off": "熄灭",
    "red": "红色",
    "green": "绿色",
    "blue": "蓝色",
    "yellow": "黄色",
    "cyan": "青色",
    "magenta": "紫色",
    "white": "白色",
}
PATTERN_LABELS = {
    "off": "熄灭",
    "steady": "常亮",
    "slow-blink": "慢闪",
    "fast-blink": "快闪",
}
MODE_COLORS = {"dual": "white", "data": "green", "sms": "blue"}
MODE_LABELS = {"dual": "双模式", "data": "网卡模式", "sms": "短信模式"}


class LEDControllerError(RuntimeError):
    pass


def load_state() -> dict[str, Any]:
    try:
        if STATE_FILE.stat().st_size > 64 * 1024:
            raise LEDControllerError("management state is unexpectedly large")
        loaded = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        return loaded if isinstance(loaded, dict) else {}
    except (OSError, ValueError):
        return {}


def thermal_maximum() -> float | None:
    values: list[float] = []
    try:
        zones = THERMAL_ROOT.glob("thermal_zone*")
    except OSError:
        return None
    for zone in zones:
        try:
            value = float((zone / "temp").read_text(encoding="ascii").strip())
            if abs(value) >= 1000:
                value /= 1000.0
            if -40.0 <= value <= 150.0:
                values.append(value)
        except (OSError, UnicodeError, ValueError):
            continue
    return max(values, default=None)


def backend_reachable() -> bool:
    try:
        with socket.create_connection((BACKEND_HOST, BACKEND_PORT), timeout=0.25):
            return True
    except OSError:
        return False


def effect(
    *,
    color: str,
    pattern: str,
    meaning: str,
    source: str,
    mode: str,
    enabled: bool,
    night_mode: bool,
    delay_on_ms: int = 0,
    delay_off_ms: int = 0,
) -> dict[str, Any]:
    mode_color = MODE_COLORS[mode]
    return {
        "status": "ok",
        "available": True,
        "enabled": enabled,
        "night_mode": night_mode,
        "mode": mode,
        "mode_label": MODE_LABELS[mode],
        "mode_color": mode_color,
        "mode_color_label": COLOR_LABELS[mode_color],
        "color": color,
        "color_label": COLOR_LABELS[color],
        "pattern": pattern,
        "pattern_label": PATTERN_LABELS[pattern],
        "meaning": meaning,
        "source": source,
        "delay_on_ms": delay_on_ms,
        "delay_off_ms": delay_off_ms,
    }


def decide_effect(
    state: dict[str, Any],
    maximum_c: float | None,
    vohive_ready: bool,
) -> dict[str, Any]:
    mode = str(state.get("work_mode", "dual"))
    if mode not in MODE_COLORS:
        mode = "dual"
    enabled = state.get("led_enabled") is not False
    night_mode = state.get("led_night_mode") is True

    if not enabled:
        return effect(
            color="off",
            pattern="off",
            meaning="状态灯已关闭",
            source="setting",
            mode=mode,
            enabled=False,
            night_mode=night_mode,
        )
    if maximum_c is not None and maximum_c >= THERMAL_CRITICAL_C:
        return effect(
            color="red",
            pattern="fast-blink",
            meaning=f"严重过热（{maximum_c:.1f}°C），请停止使用并降温",
            source="thermal-critical",
            mode=mode,
            enabled=True,
            night_mode=night_mode,
            delay_on_ms=250,
            delay_off_ms=250,
        )
    if maximum_c is not None and maximum_c >= THERMAL_WARNING_C:
        return effect(
            color="yellow",
            pattern="slow-blink",
            meaning=f"温度警告（{maximum_c:.1f}°C）",
            source="thermal-warning",
            mode=mode,
            enabled=True,
            night_mode=night_mode,
            delay_on_ms=800 if not night_mode else 500,
            delay_off_ms=800 if not night_mode else 2500,
        )

    transition = str(state.get("work_mode_transition", ""))
    if transition in MODE_COLORS:
        if night_mode:
            return effect(
                color="off",
                pattern="off",
                meaning=f"夜间模式：正在切换到{MODE_LABELS[transition]}，正常状态不亮灯",
                source="night-transition",
                mode=transition,
                enabled=True,
                night_mode=True,
            )
        color = MODE_COLORS[transition]
        return effect(
            color=color,
            pattern="slow-blink",
            meaning=f"正在切换到{MODE_LABELS[transition]}",
            source="transition",
            mode=transition,
            enabled=True,
            night_mode=False,
            delay_on_ms=900,
            delay_off_ms=900,
        )

    last_result = str(state.get("work_mode_last_result", ""))
    last_error = str(state.get("work_mode_last_error", "")).strip()
    uplink_result = str(state.get("uplink_last_result", ""))
    uplink_error = str(state.get("uplink_last_error", "")).strip()
    if last_result == "rolled-back" and last_error:
        return effect(
            color="red",
            pattern="steady",
            meaning="工作模式切换失败并已回滚",
            source="work-mode-error",
            mode=mode,
            enabled=True,
            night_mode=night_mode,
        )
    if uplink_result == "rolled-back" and uplink_error:
        return effect(
            color="yellow",
            pattern="slow-blink",
            meaning="网络方向异常，已恢复设备上网",
            source="uplink-warning",
            mode=mode,
            enabled=True,
            night_mode=night_mode,
            delay_on_ms=700,
            delay_off_ms=2300 if night_mode else 1300,
        )
    if last_result == "pending":
        return effect(
            color="yellow",
            pattern="slow-blink",
            meaning="蜂窝网络或 SIM 暂不可用，正在等待恢复",
            source="cellular-warning",
            mode=mode,
            enabled=True,
            night_mode=night_mode,
            delay_on_ms=700,
            delay_off_ms=2300 if night_mode else 1300,
        )
    if not vohive_ready:
        return effect(
            color="red",
            pattern="steady",
            meaning="VoHive 服务暂不可用",
            source="service-error",
            mode=mode,
            enabled=True,
            night_mode=night_mode,
        )
    if night_mode:
        return effect(
            color="off",
            pattern="off",
            meaning=f"夜间模式：{MODE_LABELS[mode]}运行正常，仅异常时亮灯",
            source="night-mode",
            mode=mode,
            enabled=True,
            night_mode=True,
        )

    color = MODE_COLORS[mode]
    return effect(
        color=color,
        pattern="steady",
        meaning=f"{MODE_LABELS[mode]}运行正常",
        source="work-mode",
        mode=mode,
        enabled=True,
        night_mode=False,
    )


def write_led(path: Path, value: str) -> None:
    try:
        path.write_text(value, encoding="ascii")
    except OSError as exc:
        raise LEDControllerError(f"cannot write {path.name}") from exc


def apply_effect(status: dict[str, Any]) -> None:
    paths = {channel: LED_ROOT / name for channel, name in LED_NAMES.items()}
    missing = [path.name for path in paths.values() if not path.is_dir()]
    if missing:
        raise LEDControllerError("RGB LED channels are unavailable")

    selected = set(RGB[str(status["color"])])
    for channel, path in paths.items():
        write_led(path / "trigger", "none")
        write_led(path / "brightness", "0")

    pattern = str(status["pattern"])
    if pattern == "steady":
        for channel in selected:
            write_led(paths[channel] / "brightness", "1")
    elif pattern in {"slow-blink", "fast-blink"}:
        for channel in selected:
            path = paths[channel]
            write_led(path / "trigger", "timer")
            write_led(path / "delay_on", str(int(status["delay_on_ms"])))
            write_led(path / "delay_off", str(int(status["delay_off_ms"])))


def write_runtime(status: dict[str, Any]) -> None:
    RUNTIME_FILE.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    temporary = RUNTIME_FILE.parent / f".{RUNTIME_FILE.name}.{os.getpid()}.{threading.get_ident()}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(status, stream, ensure_ascii=False, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, RUNTIME_FILE)
        os.chmod(RUNTIME_FILE, 0o644)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def current_status() -> dict[str, Any]:
    return decide_effect(load_state(), thermal_maximum(), backend_reachable())


def apply_once() -> dict[str, Any]:
    status = current_status()
    try:
        apply_effect(status)
    except LEDControllerError as exc:
        status = dict(status)
        status.update({"status": "unavailable", "available": False, "error": str(exc)})
    write_runtime(status)
    return status


def watch() -> int:
    previous = ""
    while True:
        status = current_status()
        signature = json.dumps(status, ensure_ascii=False, sort_keys=True)
        if signature != previous:
            try:
                apply_effect(status)
            except LEDControllerError as exc:
                status = dict(status)
                status.update({"status": "unavailable", "available": False, "error": str(exc)})
            write_runtime(status)
            previous = json.dumps(status, ensure_ascii=False, sort_keys=True)
        threading.Event().wait(max(POLL_SECONDS, 0.5))


def main() -> int:
    parser = argparse.ArgumentParser(prog="wangka-led")
    parser.add_argument("action", choices=("status", "apply", "watch"))
    args = parser.parse_args()
    try:
        if args.action == "watch":
            return watch()
        status = apply_once() if args.action == "apply" else current_status()
        print(json.dumps(status, ensure_ascii=False, sort_keys=True))
        return 0 if status.get("status") == "ok" else 1
    except (OSError, LEDControllerError) as exc:
        print(json.dumps({"status": "error", "message": str(exc)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
