#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
EDL=${WANGKA_EDL:-${PROJECT_ROOT}/.venv/bin/edl}
LOADER=${PROJECT_ROOT}/tools/edl/Loaders/qualcomm/factory/msm8916/007050e100000000_394a2e47cf830150_fhprg_peek.bin
RELEASE=${PROJECT_ROOT}/artifacts/UFI103S-V03/release
ABOOT=${PROJECT_ROOT}/tools/OpenStick-Builder/files/aboot.mbn
HYP=${PROJECT_ROOT}/tools/OpenStick-Builder/files/hyp.mbn
TZ=${PROJECT_ROOT}/downloads/dragonboard410c-17.09/tz.mbn
DISK_BYTES=3959422976
BACKUP_GPT_SECTOR=7733215
ROOTFS_START_SECTOR=2133088

LABEL=
ASSUME_YES=0
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: ./scripts/flash_new_device.sh --label DEVICE_LABEL [--yes] [--dry-run]

The target must be a factory-layout UFI103S-V03 in Qualcomm EDL 05c6:9008.
The normal path makes two matching full backups before any write. --yes skips
only the final typed confirmation; it never skips backup or hardware gates.
EOF
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

expect_hash() {
    actual=$(hash_file "$1")
    [ "${actual}" = "$2" ] || fail "SHA-256 mismatch: $1"
}

expect_size() {
    actual=$(wc -c < "$1" | tr -d ' ')
    [ "${actual}" = "$2" ] || fail "size mismatch: $1 (${actual}, expected $2)"
}

run_edl() {
    "${EDL}" "$@" --loader="${LOADER}" --memory=emmc
}

edl_device_count() {
    if command -v system_profiler >/dev/null 2>&1; then
        system_profiler SPUSBDataType 2>/dev/null \
            | awk 'BEGIN { RS=""; count=0 }
                /Product ID: 0x9008/ && /Vendor ID: 0x05c6/ { count++ }
                END { print count }'
    elif command -v lsusb >/dev/null 2>&1; then
        lsusb -d 05c6:9008 2>/dev/null | wc -l | tr -d ' '
    else
        fail "cannot check USB EDL state (system_profiler/lsusb missing)"
    fi
}

extract_partition() {
    source=$1
    target=$2
    start=$3
    sectors=$4
    dd if="${source}" of="${target}" bs=512 skip="${start}" count="${sectors}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --label)
            [ "$#" -ge 2 ] || fail "--label requires a value"
            LABEL=$2
            shift 2
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[ -n "${LABEL}" ] || fail "--label is required"
case "${LABEL}" in
    *[!A-Za-z0-9._-]*) fail "label may contain only A-Z, a-z, 0-9, dot, underscore and hyphen" ;;
esac

for file in "${EDL}" "${LOADER}" "${ABOOT}" "${HYP}" "${TZ}" \
    "${RELEASE}/boot.raw" "${RELEASE}/rootfs.raw" "${RELEASE}/SHA256SUMS"; do
    [ -f "${file}" ] || fail "missing required file: ${file}"
done
[ -x "${EDL}" ] || fail "EDL client is not executable: ${EDL}"

expect_hash "${LOADER}" 53f193500c03248f0d671ab57bfe9ca8a42967e97f28403294b4b3f854075aca
expect_hash "${ABOOT}" 223283b927ab8076e9a2f3dc86248b024ff5ddb3f510bb1595dc984f03a05ed2
expect_hash "${HYP}" c6414843b635a2b3e7ec58bc5a6c6c7c7aef7f5a31898dc5923c2085c9de1a2d
expect_hash "${TZ}" 8d2a0cf01e3b0c7ca257333df1adc96d85a4ccda773c8258b8d7395257008171
expect_size "${TZ}" 483468
expect_size "${RELEASE}/boot.raw" 67108864
expect_size "${RELEASE}/rootfs.raw" 1610612736

(
    cd "${RELEASE}"
    while read -r expected name; do
        [ -n "${expected}" ] || continue
        actual=$(hash_file "${name}")
        [ "${actual}" = "${expected}" ] || fail "release checksum mismatch: ${name}"
    done < SHA256SUMS
)

printf 'PREFLIGHT=PASS\n'
printf 'MODEL_GATE=UFI103S-V03\n'
printf 'CAPACITY_GATE=%s_BYTES\n' "${DISK_BYTES}"
printf 'PROTECTED=modem,modemst1,modemst2,fsc,fsg,sec,persist,sbl1,rpm\n'

if [ "${DRY_RUN}" = 1 ]; then
    printf 'DRY_RUN=PASS\n'
    printf 'NEXT=enter EDL and rerun without --dry-run\n'
    exit 0
fi

EDL_COUNT=$(edl_device_count)
[ "${EDL_COUNT}" = 1 ] \
    || fail "expected exactly one Qualcomm EDL 05c6:9008 device; found ${EDL_COUNT}"

timestamp=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=${PROJECT_ROOT}/backups/UFI103S-V03/${LABEL}-${timestamp}
mkdir -p "${BACKUP_DIR}/partitions" "${BACKUP_DIR}/gpt-debian" "${BACKUP_DIR}/verify"
READ1=${BACKUP_DIR}/original-emmc-read1.bin
READ2=${BACKUP_DIR}/original-emmc-read2.bin

printf 'BACKUP_1=START\n'
run_edl rf "${READ1}"
expect_size "${READ1}" "${DISK_BYTES}"
printf 'BACKUP_2=START\n'
run_edl rf "${READ2}"
expect_size "${READ2}" "${DISK_BYTES}"
cmp "${READ1}" "${READ2}" || fail "the two full backups are not byte-identical"
READ_HASH=$(hash_file "${READ1}")
printf '%s  %s\n%s  %s\n' \
    "${READ_HASH}" "$(basename "${READ1}")" \
    "${READ_HASH}" "$(basename "${READ2}")" \
    > "${BACKUP_DIR}/SHA256SUMS"

"${PROJECT_ROOT}/scripts/generate_device_gpt.py" \
    "${READ1}" "${BACKUP_DIR}/gpt-debian"

extract_partition "${READ1}" "${BACKUP_DIR}/partitions/modem.bin" 131072 131072
extract_partition "${READ1}" "${BACKUP_DIR}/partitions/sbl1.bin" 262144 1024
extract_partition "${READ1}" "${BACKUP_DIR}/partitions/rpm.bin" 268288 1024
extract_partition "${READ1}" "${BACKUP_DIR}/partitions/modemst1.bin" 276480 3072
extract_partition "${READ1}" "${BACKUP_DIR}/partitions/modemst2.bin" 279552 3072
extract_partition "${READ1}" "${BACKUP_DIR}/partitions/fsc.bin" 284672 2
extract_partition "${READ1}" "${BACKUP_DIR}/partitions/fsg.bin" 393280 3072
extract_partition "${READ1}" "${BACKUP_DIR}/partitions/sec.bin" 396352 32
extract_partition "${READ1}" "${BACKUP_DIR}/partitions/persist.bin" 2067552 65536

if [ "${ASSUME_YES}" != 1 ]; then
    printf '\nThis will replace Android on the connected device after two verified backups.\n'
    printf 'Type UFI103S-V03 to continue: '
    IFS= read -r confirmation
    [ "${confirmation}" = UFI103S-V03 ] || fail "confirmation did not match"
fi

GPT_DIR=${BACKUP_DIR}/gpt-debian
printf 'FLASH=START\n'
# Write backup GPT first, so an interruption before the primary write leaves
# the original primary table bootable.
run_edl ws "${BACKUP_GPT_SECTOR}" "${GPT_DIR}/gpt_backup0-ufi103s.bin"
run_edl ws 0 "${GPT_DIR}/gpt_main0-ufi103s.bin"
run_edl w aboot "${ABOOT}"
run_edl w abootbak "${ABOOT}"
run_edl w hyp "${HYP}"
run_edl w hypbak "${HYP}"
run_edl w tz "${TZ}"
run_edl w tzbak "${TZ}"
run_edl w boot "${RELEASE}/boot.raw"
run_edl w rootfs "${RELEASE}/rootfs.raw"

VERIFY=${BACKUP_DIR}/verify
run_edl rs 0 34 "${VERIFY}/gpt_main.bin"
run_edl rs "${BACKUP_GPT_SECTOR}" 33 "${VERIFY}/gpt_backup.bin"
cmp "${VERIFY}/gpt_main.bin" "${GPT_DIR}/gpt_main0-ufi103s.bin" \
    || fail "primary GPT readback mismatch"
cmp "${VERIFY}/gpt_backup.bin" "${GPT_DIR}/gpt_backup0-ufi103s.bin" \
    || fail "backup GPT readback mismatch"

run_edl r boot "${VERIFY}/boot.raw"
cmp "${VERIFY}/boot.raw" "${RELEASE}/boot.raw" || fail "boot readback mismatch"

rootfs_sectors=$((1610612736 / 512))
for sample in head middle tail; do
    case "${sample}" in
        head) offset=0 ;;
        middle) offset=$((rootfs_sectors / 2 - 1024)) ;;
        tail) offset=$((rootfs_sectors - 2048)) ;;
    esac
    run_edl rs $((ROOTFS_START_SECTOR + offset)) 2048 "${VERIFY}/rootfs-${sample}.bin"
    dd if="${RELEASE}/rootfs.raw" of="${VERIFY}/rootfs-${sample}.expected" \
        bs=512 skip="${offset}" count=2048
    cmp "${VERIFY}/rootfs-${sample}.bin" "${VERIFY}/rootfs-${sample}.expected" \
        || fail "rootfs ${sample} readback mismatch"
done

run_edl r modem,modemst1,modemst2,fsc,fsg,sec,persist \
    "${VERIFY}/modem.bin,${VERIFY}/modemst1.bin,${VERIFY}/modemst2.bin,${VERIFY}/fsc.bin,${VERIFY}/fsg.bin,${VERIFY}/sec.bin,${VERIFY}/persist.bin"
for part in modem modemst1 modemst2 fsc fsg sec persist; do
    cmp "${BACKUP_DIR}/partitions/${part}.bin" "${VERIFY}/${part}.bin" \
        || fail "protected partition changed: ${part}"
done

printf 'FLASH_VERIFY=PASS\n'
printf 'BACKUP_DIR=%s\n' "${BACKUP_DIR}"
"${EDL}" reset --loader="${LOADER}" || true
printf 'RESET_SENT=YES\n'
