#!/usr/bin/python3
"""Enforce VoHive as the single QMI owner on the onboard MSM8916 modem.

The pinned VoHive build and ModemManager both support QMI, but their recovery
loops cannot safely control this modem at the same time.  The image therefore
masks ModemManager and lets VoHive own QMI for both LTE data and SMS.  This
pre-start migration repairs intermediate AT-only test configs without logging
credentials or hardware identities.
"""

from __future__ import annotations

import os
import re
import stat
from pathlib import Path


CONFIG_PATH = Path(os.environ.get("WANGKA_VOHIVE_CONFIG", "/etc/vohive/config.yaml"))
MAX_CONFIG_BYTES = 1024 * 1024


SCALAR_RULES = (
    (
        re.compile(
            r"(?P<prefix>\bdevice_backend\s*:\s*)"
            r"(?P<quote>['\"]?)at(?P=quote)(?=\s*[,}\n])"
        ),
        r"\g<prefix>qmi",
    ),
    (
        re.compile(
            r"(?P<prefix>\bqmi_use_proxy\s*:\s*)"
            r"(?P<quote>['\"]?)false(?P=quote)(?=\s*[,}\n])"
        ),
        r"\g<prefix>true",
    ),
)


def migrate_text(text: str) -> tuple[str, bool]:
    updated = text
    for pattern, replacement in SCALAR_RULES:
        updated = pattern.sub(replacement, updated)
    return updated, updated != text


def migrate_file(path: Path = CONFIG_PATH) -> bool:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise RuntimeError("VoHive config is not a regular file")
    if info.st_size > MAX_CONFIG_BYTES:
        raise RuntimeError("VoHive config is unexpectedly large")

    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    with os.fdopen(fd, "r", encoding="utf-8") as stream:
        original = stream.read(MAX_CONFIG_BYTES + 1)
    if len(original.encode("utf-8")) > MAX_CONFIG_BYTES:
        raise RuntimeError("VoHive config is unexpectedly large")

    updated, changed = migrate_text(original)
    if not changed:
        return False

    temporary = path.parent / f".{path.name}.qmi-owner.{os.getpid()}"
    out_fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.fchmod(out_fd, stat.S_IMODE(info.st_mode))
        if hasattr(os, "fchown"):
            os.fchown(out_fd, info.st_uid, info.st_gid)
        with os.fdopen(out_fd, "w", encoding="utf-8") as stream:
            stream.write(updated)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return True


def main() -> int:
    try:
        changed = migrate_file()
    except (OSError, UnicodeError, RuntimeError) as exc:
        print(f"VOHIVE_QMI_OWNER=FAIL:{type(exc).__name__}")
        return 1
    print("VOHIVE_QMI_OWNER=CHANGED" if changed else "VOHIVE_QMI_OWNER=READY")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
