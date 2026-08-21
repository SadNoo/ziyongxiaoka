#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TOKEN_FILE=${1:-${PROJECT_ROOT}/private/host-uplink.secret}
SERVICE_NAME='UFI103S Debian ECM'
HOST_ADDRESS=192.168.5.242
PLIST=/Library/LaunchDaemons/com.sadno.wangka-host-uplink.plist
BINARY=/usr/local/libexec/wangka-host-uplinkd
SECRET_DIR='/Library/Application Support/Wangka'
SECRET_PATH="${SECRET_DIR}/host-uplink.token"
STATE_DIR=/var/db/wangka-host-uplink
BUILD_OUTPUT=/private/tmp/wangka-host-uplinkd
RENDERED_PLIST=/private/tmp/com.sadno.wangka-host-uplink.plist
ROOT_HELPER=/private/tmp/wangka-host-uplink-root.sh
TOKEN_COPY=/private/tmp/wangka-host-uplink.secret

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[ "$(uname -s)" = Darwin ] || fail 'macOS is required'
[ -f "${TOKEN_FILE}" ] || fail "missing private token file: ${TOKEN_FILE}"
TOKEN=$(tr -d '\r\n' < "${TOKEN_FILE}")
case "${TOKEN}" in
    *[!a-f0-9]*|'') fail 'pairing token must be lowercase hexadecimal' ;;
esac
[ "${#TOKEN}" -eq 64 ] || fail 'pairing token must contain 64 characters'

USB_INTERFACE=$(/usr/sbin/networksetup -listallhardwareports | awk -v wanted="${SERVICE_NAME}" '
    $0 == "Hardware Port: " wanted { getline; if ($1 == "Device:") print $2; exit }
')
[ -n "${USB_INTERFACE}" ] || fail "network service not found: ${SERVICE_NAME}"
case "${USB_INTERFACE}" in
    *[!A-Za-z0-9]*) fail 'invalid USB interface name' ;;
esac

command -v go >/dev/null 2>&1 || fail 'Go compiler is required to build the macOS helper'
(
    cd "${PROJECT_ROOT}/host/macos/wangka-host-uplinkd"
    go test .
    go build -trimpath -o "${BUILD_OUTPUT}" .
)
chmod 0755 "${BUILD_OUTPUT}"
umask 077
/usr/bin/install -m 0700 "${PROJECT_ROOT}/scripts/macos_host_uplink_root.sh" "${ROOT_HELPER}"
/usr/bin/install -m 0600 "${TOKEN_FILE}" "${TOKEN_COPY}"
trap 'rm -f "${ROOT_HELPER}" "${TOKEN_COPY}"' EXIT INT TERM
sed "s/__WANGKA_USB_INTERFACE__/${USB_INTERFACE}/g" \
    "${PROJECT_ROOT}/config/macos/com.sadno.wangka-host-uplink.plist.template" \
    > "${RENDERED_PLIST}"
/usr/bin/plutil -lint "${RENDERED_PLIST}" >/dev/null

# The device currently assigns this same lease over DHCP. Pinning it on the
# Mac keeps the host helper address stable and deliberately configures no USB
# router or DNS, so the device cannot replace the Mac default route. macOS
# displays its own administrator prompt; the password is never read here.
/usr/bin/osascript "${PROJECT_ROOT}/scripts/run_with_admin.applescript" \
    "${ROOT_HELPER}" install \
    "${USB_INTERFACE}" "${TOKEN_COPY}" "${BUILD_OUTPUT}" "${RENDERED_PLIST}"

attempt=1
while [ "${attempt}" -le 12 ]; do
    if /usr/bin/curl -fsS --max-time 2 \
        -H "X-Wangka-Token: ${TOKEN}" \
        "http://${HOST_ADDRESS}:19531/v1/status" >/dev/null; then
        printf 'MACOS_HOST_HELPER=READY\n'
        printf 'MACOS_USB_INTERFACE=%s\n' "${USB_INTERFACE}"
        printf 'MACOS_USB_ADDRESS=%s\n' "${HOST_ADDRESS}"
        exit 0
    fi
    attempt=$((attempt + 1))
    sleep 1
done

fail 'macOS host helper did not become ready'
