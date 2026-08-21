#!/usr/bin/env python3
"""Extract unique DTBs from a Qualcomm QCDT image.

QCDT v3 contains ten little-endian 32-bit words per table entry.  The
final two words are the blob offset and allocation size.  Duplicate table
entries may point at the same blob, so output is de-duplicated by that pair.
"""

from __future__ import annotations

import argparse
import pathlib
import struct


ENTRY_WORDS = {1: 5, 2: 6, 3: 10}
QCDT_MAGIC = b"QCDT"
FDT_MAGIC = 0xD00DFEED


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()

    image = args.image.read_bytes()
    if image[:4] != QCDT_MAGIC:
        raise SystemExit("not a QCDT image")

    version, count = struct.unpack_from("<II", image, 4)
    try:
        words = ENTRY_WORDS[version]
    except KeyError as exc:
        raise SystemExit(f"unsupported QCDT version: {version}") from exc

    entry_size = words * 4
    table_end = 12 + count * entry_size
    if table_end > len(image):
        raise SystemExit("QCDT table exceeds image size")

    args.output.mkdir(parents=True, exist_ok=True)
    rows = ["blob\toffset\tallocation\tfdt_size\tentry_ids"]
    seen: dict[tuple[int, int], int] = {}

    for entry_id in range(count):
        fields = struct.unpack_from(
            f"<{words}I", image, 12 + entry_id * entry_size
        )
        offset, allocation = fields[-2:]
        key = (offset, allocation)
        if key in seen:
            continue
        seen[key] = entry_id

        if offset + 8 > len(image):
            raise SystemExit(f"entry {entry_id}: DTB offset outside image")
        magic, fdt_size = struct.unpack_from(">II", image, offset)
        if magic != FDT_MAGIC:
            raise SystemExit(f"entry {entry_id}: invalid FDT magic at 0x{offset:x}")
        if fdt_size > allocation or offset + fdt_size > len(image):
            raise SystemExit(f"entry {entry_id}: invalid FDT size")

        name = f"dtb-{len(seen):03d}-entry-{entry_id:03d}.dtb"
        (args.output / name).write_bytes(image[offset : offset + fdt_size])
        rows.append(
            f"{name}\t0x{offset:x}\t0x{allocation:x}\t0x{fdt_size:x}\t"
            + ",".join(f"0x{value:x}" for value in fields[:-2])
        )

    (args.output / "manifest.tsv").write_text("\n".join(rows) + "\n")
    print(f"QCDT v{version}: {count} entries, {len(seen)} unique DTBs")


if __name__ == "__main__":
    main()
