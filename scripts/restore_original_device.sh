#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
EDL=${WANGKA_EDL:-${PROJECT_ROOT}/.venv/bin/edl}
LOADER=${PROJECT_ROOT}/tools/edl/Loaders/qualcomm/factory/msm8916/007050e100000000_394a2e47cf830150_fhprg_peek.bin
DISK_BYTES=3959422976
ASSUME_YES=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[ "$#" -ge 1 ] || fail "usage: restore_original_device.sh FULL_BACKUP [--yes]"
BACKUP=$1
shift
if [ "${1:-}" = --yes ]; then
    ASSUME_YES=1
    shift
fi
[ "$#" -eq 0 ] || fail "unknown arguments"
[ -f "${BACKUP}" ] || fail "backup not found: ${BACKUP}"
[ -x "${EDL}" ] || fail "EDL client is not executable"
[ "$(wc -c < "${BACKUP}" | tr -d ' ')" = "${DISK_BYTES}" ] \
    || fail "backup size is not the exact UFI103S-V03 eMMC size"

check_dir=$(mktemp -d)
trap 'rm -rf "${check_dir}"' EXIT INT TERM
"${PROJECT_ROOT}/scripts/generate_device_gpt.py" "${BACKUP}" "${check_dir}" >/dev/null

if [ "${ASSUME_YES}" != 1 ]; then
    printf 'This will overwrite the complete connected eMMC, including modem/NV data.\n'
    printf 'Use only the backup from this exact physical device. Type RESTORE-ORIGINAL: '
    IFS= read -r confirmation
    [ "${confirmation}" = RESTORE-ORIGINAL ] || fail "confirmation did not match"
fi

"${EDL}" wf "${BACKUP}" --loader="${LOADER}" --memory=emmc
"${EDL}" rs 0 34 "${check_dir}/readback-gpt.bin" --loader="${LOADER}" --memory=emmc
dd if="${BACKUP}" of="${check_dir}/expected-gpt.bin" bs=512 count=34
cmp "${check_dir}/readback-gpt.bin" "${check_dir}/expected-gpt.bin" \
    || fail "restored GPT readback mismatch"
printf 'RESTORE_VERIFY=PASS\n'
"${EDL}" reset --loader="${LOADER}" || true
