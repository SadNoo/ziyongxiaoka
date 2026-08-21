#!/usr/bin/env python3
"""Build the Debian GPT from an exact UFI103S-V03 factory eMMC backup.

The first 21 boot-chain/modem/NV entries and the persist entry are copied from
the target device. Only the Android boot/system/cache/recovery/userdata area is
relaid out for boot + rootfs. This script never modifies the source backup.
"""

from __future__ import annotations

import argparse
import binascii
import hashlib
import pathlib
import struct
import uuid


SECTOR_SIZE = 512
DISK_SECTORS = 7_733_248
DISK_BYTES = DISK_SECTORS * SECTOR_SIZE
LAST_LBA = DISK_SECTORS - 1
FIRST_USABLE = 34
LAST_USABLE = 7_733_214
ENTRY_LBA = 2
ENTRY_COUNT = 28
ENTRY_SIZE = 128
ENTRY_BYTES = ENTRY_COUNT * ENTRY_SIZE
BACKUP_SEGMENT_LBA = LAST_USABLE + 1
BACKUP_ENTRY_LBA = LAST_LBA - (ENTRY_BYTES + SECTOR_SIZE - 1) // SECTOR_SIZE

BOOT_START = 396_384
BOOT_END = 527_455
ROOTFS_START = 2_133_088
ROOTFS_END = LAST_USABLE

BOOT_TYPE = uuid.UUID("20117f86-e985-4357-b9ee-374bc1d8487d")
BOOT_UUID = uuid.UUID("80780b1d-0fe1-27d3-23e4-9244e62f8c46")
ROOTFS_TYPE = uuid.UUID("1b81e7e6-f50d-419b-a739-2aeef8da3335")
ROOTFS_UUID = uuid.UUID("a7ab80e8-e9d1-e8cd-f157-93f69b1d141e")

EXPECTED_STOCK = (
    ("modem", 131072, 262143),
    ("sbl1", 262144, 263167),
    ("sbl1bak", 263168, 264191),
    ("aboot", 264192, 266239),
    ("abootbak", 266240, 268287),
    ("rpm", 268288, 269311),
    ("rpmbak", 269312, 270335),
    ("tz", 270336, 271359),
    ("tzbak", 271360, 272383),
    ("hyp", 272384, 273407),
    ("hypbak", 273408, 274431),
    ("pad", 274432, 276479),
    ("modemst1", 276480, 279551),
    ("modemst2", 279552, 282623),
    ("misc", 282624, 284671),
    ("fsc", 284672, 284673),
    ("ssd", 284674, 284689),
    ("splash", 284690, 305169),
    ("DDR", 393216, 393279),
    ("fsg", 393280, 396351),
    ("sec", 396352, 396383),
)


class LayoutError(RuntimeError):
    pass


def crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def entry_name(entry: bytes) -> str:
    return entry[56:128].decode("utf-16le").rstrip("\0")


def entry_bounds(entry: bytes) -> tuple[int, int]:
    return struct.unpack_from("<QQ", entry, 32)


def make_entry(
    type_guid: uuid.UUID,
    unique_guid: uuid.UUID,
    start: int,
    end: int,
    name: str,
    attrs: int = 0,
) -> bytes:
    encoded_name = name.encode("utf-16le")
    if len(encoded_name) > 72:
        raise LayoutError(f"partition name too long: {name}")
    return struct.pack(
        "<16s16sQQQ72s",
        type_guid.bytes_le,
        unique_guid.bytes_le,
        start,
        end,
        attrs,
        encoded_name.ljust(72, b"\0"),
    )


def parse_header(block: bytes, expected_lba: int) -> dict[str, int | bytes]:
    if len(block) != SECTOR_SIZE or block[:8] != b"EFI PART":
        raise LayoutError(f"missing GPT header at LBA {expected_lba}")
    header_size = struct.unpack_from("<I", block, 12)[0]
    stored_crc = struct.unpack_from("<I", block, 16)[0]
    if not 92 <= header_size <= SECTOR_SIZE:
        raise LayoutError("invalid GPT header size")
    checked = bytearray(block[:header_size])
    struct.pack_into("<I", checked, 16, 0)
    if crc32(checked) != stored_crc:
        raise LayoutError("GPT header CRC mismatch")
    values = struct.unpack_from("<8sIIIIQQQQ16sQIII", block)
    return {
        "revision": values[1],
        "header_size": values[2],
        "current_lba": values[5],
        "backup_lba": values[6],
        "first_usable": values[7],
        "last_usable": values[8],
        "disk_guid": values[9],
        "entry_lba": values[10],
        "entry_count": values[11],
        "entry_size": values[12],
        "entry_crc": values[13],
    }


def make_header(
    template: bytes,
    *,
    current_lba: int,
    backup_lba: int,
    entry_lba: int,
    disk_guid: bytes,
    entries_crc: int,
) -> bytes:
    block = bytearray(SECTOR_SIZE)
    block[:92] = template[:92]
    struct.pack_into("<Q", block, 24, current_lba)
    struct.pack_into("<Q", block, 32, backup_lba)
    struct.pack_into("<Q", block, 40, FIRST_USABLE)
    struct.pack_into("<Q", block, 48, LAST_USABLE)
    block[56:72] = disk_guid
    struct.pack_into("<Q", block, 72, entry_lba)
    struct.pack_into("<I", block, 80, ENTRY_COUNT)
    struct.pack_into("<I", block, 84, ENTRY_SIZE)
    struct.pack_into("<I", block, 88, entries_crc)
    struct.pack_into("<I", block, 16, 0)
    header_size = struct.unpack_from("<I", block, 12)[0]
    struct.pack_into("<I", block, 16, crc32(block[:header_size]))
    return bytes(block)


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=pathlib.Path, help="exact factory full eMMC backup")
    parser.add_argument("output_dir", type=pathlib.Path)
    args = parser.parse_args()

    if args.source.stat().st_size != DISK_BYTES:
        raise LayoutError(
            f"wrong eMMC size: {args.source.stat().st_size}; expected {DISK_BYTES}"
        )

    with args.source.open("rb") as source:
        mbr = source.read(SECTOR_SIZE)
        primary_template = source.read(SECTOR_SIZE)
        source.seek(ENTRY_LBA * SECTOR_SIZE)
        original_entries = source.read(ENTRY_BYTES)
        source.seek(LAST_LBA * SECTOR_SIZE)
        backup_template = source.read(SECTOR_SIZE)

    if mbr[510:512] != b"\x55\xaa" or mbr[450] != 0xEE:
        raise LayoutError("protective MBR validation failed")

    primary = parse_header(primary_template, 1)
    backup = parse_header(backup_template, LAST_LBA)
    required = {
        "current_lba": 1,
        "backup_lba": LAST_LBA,
        "first_usable": FIRST_USABLE,
        "last_usable": LAST_USABLE,
        "entry_lba": ENTRY_LBA,
        "entry_count": ENTRY_COUNT,
        "entry_size": ENTRY_SIZE,
    }
    for key, expected in required.items():
        if primary[key] != expected:
            raise LayoutError(f"unexpected primary GPT {key}: {primary[key]}")
    if backup["current_lba"] != LAST_LBA or backup["backup_lba"] != 1:
        raise LayoutError("backup GPT LBA pointers do not match this device")
    if (
        backup["first_usable"] != FIRST_USABLE
        or backup["last_usable"] != LAST_USABLE
        or backup["entry_count"] != ENTRY_COUNT
        or backup["entry_size"] != ENTRY_SIZE
    ):
        raise LayoutError("backup GPT geometry does not match this device")
    if primary["disk_guid"] != backup["disk_guid"]:
        raise LayoutError("primary/backup disk GUID mismatch")
    if crc32(original_entries) != primary["entry_crc"]:
        raise LayoutError("factory partition-entry CRC mismatch")
    with args.source.open("rb") as source:
        source.seek(int(backup["entry_lba"]) * SECTOR_SIZE)
        backup_entries = source.read(ENTRY_BYTES)
    if crc32(backup_entries) != backup["entry_crc"]:
        raise LayoutError("factory backup partition-entry CRC mismatch")
    if backup_entries != original_entries:
        raise LayoutError("factory primary/backup partition entries differ")

    entries = [
        original_entries[index * ENTRY_SIZE : (index + 1) * ENTRY_SIZE]
        for index in range(ENTRY_COUNT)
    ]
    for index, expected in enumerate(EXPECTED_STOCK):
        name, start, end = expected
        if entry_name(entries[index]) != name or entry_bounds(entries[index]) != (start, end):
            raise LayoutError(f"factory partition {index + 1} does not match {expected}")

    persist = next((entry for entry in entries if entry_name(entry) == "persist"), None)
    if persist is None or entry_bounds(persist) != (2_067_552, 2_133_087):
        raise LayoutError("factory persist partition is missing or moved")

    new_entries = entries[:21]
    new_entries.append(make_entry(BOOT_TYPE, BOOT_UUID, BOOT_START, BOOT_END, "boot"))
    new_entries.append(persist)
    new_entries.append(
        make_entry(ROOTFS_TYPE, ROOTFS_UUID, ROOTFS_START, ROOTFS_END, "rootfs")
    )
    new_entries.extend([bytes(ENTRY_SIZE)] * (ENTRY_COUNT - len(new_entries)))
    entry_blob = b"".join(new_entries)
    entries_crc = crc32(entry_blob)

    primary_header = make_header(
        primary_template,
        current_lba=1,
        backup_lba=LAST_LBA,
        entry_lba=ENTRY_LBA,
        disk_guid=primary["disk_guid"],
        entries_crc=entries_crc,
    )
    backup_header = make_header(
        backup_template,
        current_lba=LAST_LBA,
        backup_lba=1,
        entry_lba=BACKUP_ENTRY_LBA,
        disk_guid=primary["disk_guid"],
        entries_crc=entries_crc,
    )

    protective_mbr = bytearray(mbr)
    protective_mbr[446:510] = bytes(64)
    protective_mbr[446:462] = struct.pack(
        "<B3sB3sII",
        0,
        b"\x00\x02\x00",
        0xEE,
        b"\xff\xff\xff",
        1,
        DISK_SECTORS - 1,
    )
    protective_mbr[510:512] = b"\x55\xaa"

    primary_segment = bytearray(34 * SECTOR_SIZE)
    primary_segment[:SECTOR_SIZE] = protective_mbr
    primary_segment[SECTOR_SIZE : 2 * SECTOR_SIZE] = primary_header
    primary_segment[ENTRY_LBA * SECTOR_SIZE : ENTRY_LBA * SECTOR_SIZE + ENTRY_BYTES] = entry_blob

    backup_segment = bytearray((LAST_LBA - BACKUP_SEGMENT_LBA + 1) * SECTOR_SIZE)
    backup_entry_offset = (BACKUP_ENTRY_LBA - BACKUP_SEGMENT_LBA) * SECTOR_SIZE
    backup_segment[backup_entry_offset : backup_entry_offset + ENTRY_BYTES] = entry_blob
    backup_segment[-SECTOR_SIZE:] = backup_header

    args.output_dir.mkdir(parents=True, exist_ok=True)
    outputs = {
        "gpt_main0-ufi103s.bin": bytes(primary_segment),
        "gpt_backup0-ufi103s.bin": bytes(backup_segment),
        "gpt_both0-ufi103s.bin": bytes(primary_segment + backup_segment),
    }
    for name, data in outputs.items():
        (args.output_dir / name).write_bytes(data)

    layout = [
        "# Generated from the target device; identifiers intentionally omitted.",
        f"disk-sectors={DISK_SECTORS}",
        "stock-entries-preserved=1-21",
        f"boot={BOOT_START}:{BOOT_END - BOOT_START + 1}",
        "persist=2067552:65536",
        f"rootfs={ROOTFS_START}:{ROOTFS_END - ROOTFS_START + 1}",
    ]
    (args.output_dir / "partition-layout.txt").write_text("\n".join(layout) + "\n")

    checksum_names = list(outputs) + ["partition-layout.txt"]
    checksums = "".join(
        f"{sha256(args.output_dir / name)}  {name}\n" for name in checksum_names
    )
    (args.output_dir / "SHA256SUMS").write_text(checksums)

    print("GPT_GENERATION=PASS")
    print("MODEL=UFI103S-V03")
    print("STOCK_ENTRIES_1_TO_21=PRESERVED")
    print("PERSIST_ENTRY=PRESERVED")
    print(f"OUTPUT={args.output_dir}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (LayoutError, OSError, ValueError) as error:
        raise SystemExit(f"FAIL: {error}")
