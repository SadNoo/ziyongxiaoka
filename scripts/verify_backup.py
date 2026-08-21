#!/usr/bin/env python3
"""Verify repeated eMMC reads and partition dumps without modifying them."""

from __future__ import annotations

import argparse
import hashlib
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


CHUNK_SIZE = 8 * 1024 * 1024


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(CHUNK_SIZE):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_region(path: Path, offset: int, length: int) -> str:
    digest = hashlib.sha256()
    remaining = length
    with path.open("rb") as stream:
        stream.seek(offset)
        while remaining:
            chunk = stream.read(min(CHUNK_SIZE, remaining))
            if not chunk:
                raise EOFError(
                    f"{path} ended while reading offset={offset}, length={length}"
                )
            digest.update(chunk)
            remaining -= len(chunk)
    return digest.hexdigest()


def verify(root: Path) -> bool:
    image1 = root / "original-emmc-read1.bin"
    image2 = root / "original-emmc-read2.bin"
    xml_path = root / "partitions" / "rawprogram0.xml"

    required = (image1, image2, xml_path)
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        for path in missing:
            print(f"MISSING {path}")
        return False

    ok = True
    size1 = image1.stat().st_size
    size2 = image2.stat().st_size
    hash1 = sha256_file(image1)
    hash2 = sha256_file(image2)
    if size1 == size2 and hash1 == hash2:
        print(f"PASS full images: {size1} bytes, sha256={hash1}")
    else:
        print(
            "FAIL full images differ: "
            f"read1={size1}/{hash1}, read2={size2}/{hash2}"
        )
        ok = False

    root_element = ET.parse(xml_path).getroot()
    checked = 0
    for program in root_element.findall("program"):
        filename = program.get("filename", "")
        label = program.get("label", filename)
        if not filename or filename.startswith("gpt_"):
            continue

        dump_path = root / "partitions" / filename
        if not dump_path.is_file():
            continue

        sector_size = int(program.attrib["SECTOR_SIZE_IN_BYTES"])
        start_sector_text = program.attrib["start_sector"]
        if not start_sector_text.isdigit():
            print(f"SKIP {label}: non-numeric start sector")
            continue

        start_sector = int(start_sector_text)
        sector_count = int(program.attrib["num_partition_sectors"])
        expected_size = sector_size * sector_count
        actual_size = dump_path.stat().st_size
        if actual_size != expected_size:
            print(
                f"FAIL {label}: size {actual_size}, expected {expected_size} bytes"
            )
            ok = False
            continue

        dump_hash = sha256_file(dump_path)
        image_hash = sha256_region(
            image1, start_sector * sector_size, expected_size
        )
        checked += 1
        if dump_hash == image_hash:
            print(f"PASS {label}: {actual_size} bytes, sha256={dump_hash}")
        else:
            print(
                f"FAIL {label}: partition sha256={dump_hash}, "
                f"image region sha256={image_hash}"
            )
            ok = False

    if checked == 0:
        print("FAIL no partition dumps were checked")
        ok = False
    else:
        print(f"Checked {checked} independently dumped partitions.")

    return ok


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "backup_root",
        type=Path,
        help="Directory containing original-emmc-read*.bin and partitions/",
    )
    args = parser.parse_args()
    return 0 if verify(args.backup_root.resolve()) else 1


if __name__ == "__main__":
    sys.exit(main())
