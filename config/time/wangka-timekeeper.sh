#!/bin/sh
set -eu

BUILD_EPOCH_FILE=/usr/lib/wangka/build-epoch
STATE_DIR=/var/lib/wangka-management
LAST_EPOCH_FILE=${STATE_DIR}/last-trusted-epoch

read_epoch() {
    [ -f "$1" ] || return 1
    value=$(sed -n '1p' "$1")
    case "${value}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${value}" -ge 1735689600 ] && [ "${value}" -le 4102444800 ] || return 1
    printf '%s\n' "${value}"
}

save_epoch() {
    install -d -m 0700 "${STATE_DIR}"
    now=$(date -u +%s)
    build=$(read_epoch "${BUILD_EPOCH_FILE}" || printf '1735689600\n')
    [ "${now}" -ge "${build}" ] || return 0
    temporary=${LAST_EPOCH_FILE}.tmp.$$
    umask 077
    printf '%s\n' "${now}" > "${temporary}"
    mv "${temporary}" "${LAST_EPOCH_FILE}"
    chmod 0600 "${LAST_EPOCH_FILE}"
}

case "${1:-load}" in
    load)
        best=$(read_epoch "${BUILD_EPOCH_FILE}" || printf '1735689600\n')
        if saved=$(read_epoch "${LAST_EPOCH_FILE}" 2>/dev/null) && [ "${saved}" -gt "${best}" ]; then
            best=${saved}
        fi
        now=$(date -u +%s)
        if [ "${now}" -lt "${best}" ]; then
            date -u --set="@${best}" >/dev/null
        fi
        save_epoch
        printf 'WANGKA_TIMEKEEPER=LOADED\n'
        ;;
    save)
        save_epoch
        printf 'WANGKA_TIMEKEEPER=SAVED\n'
        ;;
    *)
        printf 'usage: wangka-timekeeper {load|save}\n' >&2
        exit 2
        ;;
esac
