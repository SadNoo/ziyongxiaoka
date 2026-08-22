#!/usr/bin/python3
"""Persist and apply the device's cellular work mode.

The mode state is also consumed by the pinned VoHive patch so that data mode
can stop SMS polling and indications without handing QMI ownership to another
daemon.  This helper never accepts shell fragments or caller supplied paths.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator


STATE_DIR = Path(os.environ.get("WANGKA_STATE_DIR", "/var/lib/wangka-management"))
STATE_FILE = STATE_DIR / "state.json"
LOCK_FILE = STATE_DIR / "state.lock"
OPERATION_LOCK_FILE = STATE_DIR / "work-mode.lock"
MODEM_COMMAND = os.environ.get("WANGKA_MODEM_COMMAND", "/usr/local/sbin/wangka-modem")
SYSTEMCTL_COMMAND = os.environ.get("WANGKA_SYSTEMCTL_COMMAND", "/usr/bin/systemctl")
VALID_MODES = {"dual", "data", "sms"}
DEFAULT_MODE = "dual"
MODEM_TIMEOUT_SECONDS = 120
SERVICE_TIMEOUT_SECONDS = 90


class WorkModeError(RuntimeError):
    pass


def default_state() -> dict[str, Any]:
    return {
        "initialized": False,
        "generation": 0,
        "uplink_mode": "device-uplink",
        "work_mode": DEFAULT_MODE,
        "work_mode_transition": "",
        "work_mode_last_result": "never",
        "work_mode_last_error": "",
        "work_mode_changed_at": 0,
    }


def normalize_state(loaded: Any) -> dict[str, Any]:
    state = default_state()
    if isinstance(loaded, dict):
        state.update(loaded)
    if state.get("work_mode") not in VALID_MODES:
        state["work_mode"] = DEFAULT_MODE
    if state.get("work_mode_transition") not in VALID_MODES:
        state["work_mode_transition"] = ""
    return state


def load_state() -> dict[str, Any]:
    try:
        if STATE_FILE.stat().st_size > 64 * 1024:
            raise WorkModeError("management state is unexpectedly large")
        return normalize_state(json.loads(STATE_FILE.read_text(encoding="utf-8")))
    except FileNotFoundError:
        return default_state()
    except (OSError, ValueError) as exc:
        raise WorkModeError("management state is invalid") from exc


def save_state(state: dict[str, Any]) -> None:
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(STATE_DIR, 0o700)
    temporary = STATE_DIR / f".state.work-mode.{os.getpid()}.{threading.get_ident()}"
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


@contextmanager
def exclusive_lock() -> Iterator[None]:
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(STATE_DIR, 0o700)
    fd = os.open(LOCK_FILE, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        os.chmod(LOCK_FILE, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


class OperationLock:
    """Prevent duplicate mode changes without queueing more helper processes."""

    def __init__(self) -> None:
        self.fd: int | None = None
        self.acquired = False

    def __enter__(self) -> "OperationLock":
        STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(STATE_DIR, 0o700)
        self.fd = os.open(OPERATION_LOCK_FILE, os.O_RDWR | os.O_CREAT, 0o600)
        os.chmod(OPERATION_LOCK_FILE, 0o600)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.acquired = True
        except BlockingIOError:
            self.acquired = False
        return self

    def __exit__(self, *_: Any) -> None:
        if self.fd is None:
            return
        if self.acquired:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)
        self.fd = None


def run_modem(action: str) -> dict[str, Any]:
    if action not in {"data-suspend", "reconnect-saved-uplink"}:
        raise WorkModeError("unsupported modem action")
    result = subprocess.run(
        [MODEM_COMMAND, action],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=MODEM_TIMEOUT_SECONDS,
        check=False,
    )
    try:
        payload = json.loads(result.stdout)
    except ValueError as exc:
        raise WorkModeError("modem helper returned an invalid result") from exc
    if not isinstance(payload, dict):
        raise WorkModeError("modem helper returned an invalid result")
    if result.returncode != 0:
        detail = str(payload.get("message", "modem helper rejected the mode change"))
        raise WorkModeError(detail[:240])
    status = str(payload.get("status", ""))
    if status not in {"ok", "skipped"}:
        raise WorkModeError("modem helper did not complete the mode change")
    return payload


def restart_vohive() -> None:
    result = subprocess.run(
        [SYSTEMCTL_COMMAND, "restart", "vohive.service"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=SERVICE_TIMEOUT_SECONDS,
        check=False,
    )
    if result.returncode != 0:
        raise WorkModeError("VoHive did not restart for the SMS engine change")


def crosses_data_mode(left: str, right: str) -> bool:
    return (left == "data") != (right == "data")


def public_status(state: dict[str, Any]) -> dict[str, Any]:
    mode = str(state.get("work_mode", DEFAULT_MODE))
    return {
        "status": "ok",
        "mode": mode,
        "transition": str(state.get("work_mode_transition", "")),
        "data_enabled": mode in {"dual", "data"},
        "sms_enabled": mode in {"dual", "sms"},
        "last_result": str(state.get("work_mode_last_result", "never")),
        "last_error": str(state.get("work_mode_last_error", "")),
        "changed_at": int(state.get("work_mode_changed_at", 0) or 0),
    }


def finish_state(state: dict[str, Any], mode: str, result: str, error: str = "") -> None:
    state["work_mode"] = mode
    state["work_mode_transition"] = ""
    state["work_mode_last_result"] = result
    state["work_mode_last_error"] = error[:240]
    state["work_mode_changed_at"] = int(time.time())
    save_state(state)


def best_effort_restore(mode: str, restart_sms_engine: bool = False) -> None:
    try:
        if restart_sms_engine:
            restart_vohive()
        if mode == "sms":
            run_modem("data-suspend")
        else:
            run_modem("reconnect-saved-uplink")
    except (OSError, subprocess.TimeoutExpired, WorkModeError):
        pass


def switch_mode(target: str) -> dict[str, Any]:
    if target not in VALID_MODES:
        raise WorkModeError("work mode must be dual, data, or sms")

    with OperationLock() as operation:
        if not operation.acquired:
            current = load_state()
            if current.get("work_mode_transition") == target:
                return public_status(current)
            raise WorkModeError("another work mode operation is already running")
        with exclusive_lock():
            return switch_mode_locked(target)


def switch_mode_locked(target: str) -> dict[str, Any]:
    previous = load_state()
    previous_mode = str(previous.get("work_mode", DEFAULT_MODE))
    if previous_mode == target and not previous.get("work_mode_transition"):
        return public_status(previous)

    transitioning = dict(previous)
    transitioning["work_mode_transition"] = target
    transitioning["work_mode_last_result"] = "switching"
    transitioning["work_mode_last_error"] = ""
    # Commit the target mode before touching packet data.  The patched
    # VoHive worker observes this file and stops SMS work first in data
    # mode; on rollback we atomically restore the previous mode.
    transitioning["work_mode"] = target
    save_state(transitioning)

    try:
        restart_sms_engine = crosses_data_mode(previous_mode, target)
        if restart_sms_engine:
            # The patched VoHive reads work_mode while constructing its
            # QMI manager. Restarting makes data mode disable WMS at the
            # modem layer instead of merely hiding SMS in the page.
            restart_vohive()
        modem = run_modem(
            "data-suspend" if target == "sms" else "reconnect-saved-uplink"
        )
        finish_state(transitioning, target, str(modem.get("status", "ok")))
        result = public_status(transitioning)
        result["modem"] = {
            "status": str(modem.get("status", "")),
            "reason": str(modem.get("reason", "")),
        }
        return result
    except (OSError, subprocess.TimeoutExpired, WorkModeError) as exc:
        rollback = dict(previous)
        finish_state(rollback, previous_mode, "rolled-back", str(exc))
        best_effort_restore(
            previous_mode,
            crosses_data_mode(previous_mode, target),
        )
        raise WorkModeError(f"mode switch failed and was rolled back: {exc}") from exc


def reconcile() -> dict[str, Any]:
    with OperationLock() as operation:
        if not operation.acquired:
            result = public_status(load_state())
            result["reconcile_skipped"] = "work-mode-operation-in-progress"
            return result
        with exclusive_lock():
            return reconcile_locked()


def reconcile_locked() -> dict[str, Any]:
    state = load_state()
    mode = str(state.get("work_mode", DEFAULT_MODE))
    if state.get("work_mode_transition"):
        state["work_mode_transition"] = ""
        state["work_mode_last_result"] = "recovered-after-interruption"
        save_state(state)
    if mode != "sms":
        # Packet-data recovery belongs to wangka-uplink, which first checks
        # whether the wwan default route is actually missing. Reconnecting
        # here every 30 seconds used to cycle an already healthy LTE bearer.
        result = public_status(state)
        result["reconcile_skipped"] = "uplink-manager-owns-data-recovery"
        return result
    try:
        modem = run_modem("data-suspend")
        state["work_mode_last_error"] = ""
        if state.get("work_mode_last_result") == "never":
            state["work_mode_last_result"] = str(modem.get("status", "ok"))
        save_state(state)
    except (OSError, subprocess.TimeoutExpired, WorkModeError) as exc:
        # A cold modem may not be ready yet.  Keep the selected mode and
        # surface the bounded error; the existing timer retries later.
        state["work_mode_last_result"] = "pending"
        state["work_mode_last_error"] = str(exc)[:240]
        save_state(state)
    return public_status(state)


def main() -> int:
    parser = argparse.ArgumentParser(prog="wangka-work-mode")
    subparsers = parser.add_subparsers(dest="action", required=True)
    subparsers.add_parser("status")
    switch = subparsers.add_parser("switch")
    switch.add_argument("mode", choices=sorted(VALID_MODES))
    subparsers.add_parser("reconcile")
    args = parser.parse_args()

    try:
        if args.action == "status":
            payload = public_status(load_state())
        elif args.action == "switch":
            payload = switch_mode(args.mode)
        else:
            payload = reconcile()
        print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
        return 0
    except WorkModeError as exc:
        print(
            json.dumps({"status": "error", "message": str(exc)}, ensure_ascii=False),
            file=sys.stdout,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
