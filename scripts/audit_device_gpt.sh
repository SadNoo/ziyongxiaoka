#!/bin/sh
set -eu

GPT_DIR=${1:-artifacts/UFI103S-V03}
ORIGINAL_EMMC=${2:-backups/UFI103S-V03/2026-08-21/original-emmc-read1.bin}
IMAGE_DIR=${3:-tools/OpenStick-Builder}
DISK_BYTES=3959422976
BACKUP_GPT_SECTOR=7733215
WORK_DIR=$(mktemp -d)
RECONSTRUCTED="${WORK_DIR}/gpt-ufi103s.img"

cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT INT TERM

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

(
    cd "${GPT_DIR}"
    sha256sum -c SHA256SUMS
)

truncate -s "${DISK_BYTES}" "${RECONSTRUCTED}"
dd if="${GPT_DIR}/gpt_main0-ufi103s.bin" of="${RECONSTRUCTED}" \
    bs=512 count=34 conv=notrunc status=none
dd if="${GPT_DIR}/gpt_backup0-ufi103s.bin" of="${RECONSTRUCTED}" \
    bs=512 seek="${BACKUP_GPT_SECTOR}" count=33 conv=notrunc status=none
sfdisk --verify "${RECONSTRUCTED}"

# All 21 stock boot-chain and modem/NV partition entries must remain exact.
cmp -n 2688 -i 1024:1024 \
    "${ORIGINAL_EMMC}" "${GPT_DIR}/gpt_main0-ufi103s.bin" \
    || fail "stock partition entries 1-21 changed"

dd if="${GPT_DIR}/gpt_both0-ufi103s.bin" of="${WORK_DIR}/both-main.bin" \
    bs=512 count=34 status=none
dd if="${GPT_DIR}/gpt_both0-ufi103s.bin" of="${WORK_DIR}/both-backup.bin" \
    bs=512 skip=34 count=33 status=none
cmp "${WORK_DIR}/both-main.bin" "${GPT_DIR}/gpt_main0-ufi103s.bin" \
    || fail "combined GPT primary segment mismatch"
cmp "${WORK_DIR}/both-backup.bin" "${GPT_DIR}/gpt_backup0-ufi103s.bin" \
    || fail "combined GPT backup segment mismatch"

LAYOUT="${WORK_DIR}/layout.sfdisk"
sfdisk --dump "${RECONSTRUCTED}" > "${LAYOUT}"
grep -q 'start= *396384, size= *131072,.*uuid=80780B1D-0FE1-27D3-23E4-9244E62F8C46, name="boot"' \
    "${LAYOUT}" || fail "boot layout or GUID mismatch"
grep -q 'start= *270336, size= *1024,.*uuid=2C6F74BE-4F53-E91D-93A4-CCDF6B083658, name="tz"' \
    "${LAYOUT}" || fail "primary TZ layout mismatch"
grep -q 'start= *271360, size= *1024,.*uuid=AD543DB5-3B76-23ED-F0E7-0BFC76A20867, name="tzbak"' \
    "${LAYOUT}" || fail "backup TZ layout mismatch"
grep -q 'start= *2067552, size= *65536,.*uuid=7B8DDECB-A286-77E1-0CD3-8439E1EA51FE, name="persist"' \
    "${LAYOUT}" || fail "persist location or GUID mismatch"
grep -q 'start= *2133088, size= *5600127,.*uuid=A7AB80E8-E9D1-E8CD-F157-93F69B1D141E, name="rootfs"' \
    "${LAYOUT}" || fail "rootfs layout or GUID mismatch"

BOOT_BYTES=$(stat -c '%s' "${IMAGE_DIR}/boot.raw")
ROOTFS_BYTES=$(stat -c '%s' "${IMAGE_DIR}/rootfs.raw")
[ "${BOOT_BYTES}" -le $((131072 * 512)) ] || fail "boot image exceeds partition"
[ "${ROOTFS_BYTES}" -le $((5600127 * 512)) ] || fail "rootfs image exceeds partition"

printf 'GPT_AUDIT=PASS\n'
printf 'STOCK_ENTRIES_1_TO_21=BYTE_IDENTICAL\n'
printf 'TZ_START_SECTOR=270336\n'
printf 'TZ_SECTORS=1024\n'
printf 'TZBAK_START_SECTOR=271360\n'
printf 'TZBAK_SECTORS=1024\n'
printf 'BOOT_START_SECTOR=396384\n'
printf 'BOOT_SECTORS=131072\n'
printf 'PERSIST_START_SECTOR=2067552\n'
printf 'PERSIST_SECTORS=65536\n'
printf 'ROOTFS_START_SECTOR=2133088\n'
printf 'ROOTFS_SECTORS=5600127\n'
printf 'COMBINED_GPT_SEGMENTS=MATCH\n'
