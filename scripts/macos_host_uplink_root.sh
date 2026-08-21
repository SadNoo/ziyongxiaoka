#!/bin/sh
set -eu

ACTION=${1:-}
SERVICE_NAME='UFI103S Debian ECM'
PLIST=/Library/LaunchDaemons/com.sadno.wangka-host-uplink.plist
BINARY=/usr/local/libexec/wangka-host-uplinkd
SECRET_DIR='/Library/Application Support/Wangka'
SECRET_PATH="${SECRET_DIR}/host-uplink.token"
STATE_DIR=/var/db/wangka-host-uplink

[ "$(id -u)" -eq 0 ] || { printf 'FAIL: administrator privileges required\n' >&2; exit 1; }

case "${ACTION}" in
    install)
        [ "$#" -eq 5 ] || { printf 'FAIL: invalid install arguments\n' >&2; exit 1; }
        USB_INTERFACE=$2
        TOKEN_FILE=$3
        BUILD_OUTPUT=$4
        RENDERED_PLIST=$5
        case "${USB_INTERFACE}" in *[!A-Za-z0-9]*|'') printf 'FAIL: invalid USB interface\n' >&2; exit 1 ;; esac
        [ -f "${TOKEN_FILE}" ] && [ ! -L "${TOKEN_FILE}" ] || { printf 'FAIL: invalid token file\n' >&2; exit 1; }
        [ -f "${BUILD_OUTPUT}" ] && [ ! -L "${BUILD_OUTPUT}" ] || { printf 'FAIL: invalid helper binary\n' >&2; exit 1; }
        [ -f "${RENDERED_PLIST}" ] && [ ! -L "${RENDERED_PLIST}" ] || { printf 'FAIL: invalid launchd file\n' >&2; exit 1; }
        /usr/sbin/networksetup -setmanual "${SERVICE_NAME}" 192.168.5.242 255.255.255.0 0.0.0.0
        /usr/sbin/networksetup -setdnsservers "${SERVICE_NAME}" Empty
        /usr/bin/install -d -m 0755 /usr/local/libexec
        /usr/bin/install -d -m 0700 "${SECRET_DIR}" "${STATE_DIR}"
        /usr/bin/install -m 0755 "${BUILD_OUTPUT}" "${BINARY}"
        /usr/bin/install -m 0600 "${TOKEN_FILE}" "${SECRET_PATH}"
        /usr/bin/install -o root -g wheel -m 0644 "${RENDERED_PLIST}" "${PLIST}"
        /bin/launchctl bootout system "${PLIST}" >/dev/null 2>&1 || true
        /bin/launchctl bootstrap system "${PLIST}"
        /bin/launchctl kickstart -k system/com.sadno.wangka-host-uplink
        ;;
    uninstall)
        [ "$#" -eq 1 ] || { printf 'FAIL: invalid uninstall arguments\n' >&2; exit 1; }
        /bin/launchctl bootout system "${PLIST}" >/dev/null 2>&1 || true
        /bin/rm -f "${PLIST}" "${BINARY}" "${SECRET_PATH}" "${STATE_DIR}/state.json"
        /bin/rmdir "${SECRET_DIR}" "${STATE_DIR}" >/dev/null 2>&1 || true
        /usr/sbin/networksetup -setdhcp "${SERVICE_NAME}"
        /usr/sbin/networksetup -setdnsservers "${SERVICE_NAME}" Empty
        ;;
    *)
        printf 'FAIL: action must be install or uninstall\n' >&2
        exit 1
        ;;
esac
