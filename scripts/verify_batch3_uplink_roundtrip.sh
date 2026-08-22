#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CREDENTIAL_FILE=${PROJECT_ROOT}/private/device-credentials.env

[ -f "${CREDENTIAL_FILE}" ] || {
    printf 'FAIL: missing private credentials\n' >&2
    exit 1
}
set -a
. "${CREDENTIAL_FILE}"
set +a

device_mode() {
    "${PROJECT_ROOT}/scripts/ssh-run.expect" \
        "sudo /usr/local/sbin/wangka-uplink device-uplink >/dev/null" >/dev/null 2>&1 || true
}
trap device_mode EXIT INT TERM

"${PROJECT_ROOT}/scripts/ssh-run.expect" "set -eu
sudo /usr/local/sbin/wangka-uplink host-uplink >/dev/null
ip -4 route show default | grep -q 'via 192.168.5.242 dev usb0'
getent ahostsv4 baidu.com >/dev/null
curl -L -sS --max-time 15 -o /dev/null https://www.baidu.com
curl -sS --max-time 10 -o /dev/null http://192.168.5.1/
sudo /usr/local/sbin/wangka-modem status >/dev/null
sudo /usr/local/sbin/wangka-modem sms-list >/dev/null
sudo /usr/local/sbin/wangka-uplink device-uplink >/dev/null
! ip -4 route show default | grep -q ' dev usb0 '
ip -4 route show default | grep -q ' dev wwan0 '
getent ahostsv4 baidu.com >/dev/null
curl -L -sS --max-time 15 -o /dev/null https://www.baidu.com
curl -sS --max-time 10 -o /dev/null http://192.168.5.1/
sudo /usr/local/sbin/wangka-modem status >/dev/null
sudo /usr/local/sbin/wangka-modem sms-list >/dev/null"

trap - EXIT INT TERM
printf 'BATCH3_UPLINK_ROUNDTRIP=PASS\n'
printf 'FINAL_MODE=device-uplink\n'
