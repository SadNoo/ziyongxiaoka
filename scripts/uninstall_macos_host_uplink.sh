#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TOKEN_FILE=${1:-${PROJECT_ROOT}/private/host-uplink.secret}
SERVICE_NAME='UFI103S Debian ECM'
PLIST=/Library/LaunchDaemons/com.sadno.wangka-host-uplink.plist
ROOT_HELPER=/private/tmp/wangka-host-uplink-root.sh

[ "$(uname -s)" = Darwin ] || { printf 'FAIL: macOS is required\n' >&2; exit 1; }
[ -f "${TOKEN_FILE}" ] || { printf 'FAIL: private token file is required\n' >&2; exit 1; }
TOKEN=$(tr -d '\r\n' < "${TOKEN_FILE}")

# Ask the helper to remove only its own PF anchor and forwarding reference.
/usr/bin/curl -fsS --max-time 3 -X POST \
    -H "X-Wangka-Token: ${TOKEN}" \
    -H 'Content-Type: application/json' \
    --data '{}' http://192.168.5.242:19531/v1/disable >/dev/null 2>&1 || true

/usr/bin/install -m 0700 "${PROJECT_ROOT}/scripts/macos_host_uplink_root.sh" "${ROOT_HELPER}"
trap 'rm -f "${ROOT_HELPER}"' EXIT INT TERM
/usr/bin/osascript "${PROJECT_ROOT}/scripts/run_with_admin.applescript" \
    "${ROOT_HELPER}" uninstall
printf 'MACOS_HOST_HELPER=REMOVED\n'
printf 'MACOS_USB_CONFIGURATION=DHCP\n'
