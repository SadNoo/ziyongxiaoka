#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CREDENTIAL_FILE=${PROJECT_ROOT}/private/device-credentials.env
STAGE=/tmp/wangka-led-deploy

[ -f "${CREDENTIAL_FILE}" ] || {
    printf 'FAIL: missing %s\n' "${CREDENTIAL_FILE}" >&2
    exit 1
}
set -a
. "${CREDENTIAL_FILE}"
set +a
[ -n "${WANGKA_USER_PASSWORD:-}" ] || {
    printf 'FAIL: private SSH password is empty\n' >&2
    exit 1
}

"${PROJECT_ROOT}/scripts/ssh-run.expect" \
    "sudo install -d -o user -g user -m 0700 ${STAGE}"

"${PROJECT_ROOT}/scripts/scp-to-device.expect" \
    "${PROJECT_ROOT}/config/led/wangka-led-controller.py" \
    "${STAGE}/wangka-led"
"${PROJECT_ROOT}/scripts/scp-to-device.expect" \
    "${PROJECT_ROOT}/config/led/wangka-led.service" \
    "${STAGE}/wangka-led.service"
"${PROJECT_ROOT}/scripts/scp-to-device.expect" \
    "${PROJECT_ROOT}/config/vohive/wangka-management-proxy.py" \
    "${STAGE}/wangka-management-proxy"

"${PROJECT_ROOT}/scripts/ssh-run.expect" "set -eu
sudo install -m 0755 ${STAGE}/wangka-led /usr/local/sbin/wangka-led
sudo install -m 0644 ${STAGE}/wangka-led.service /etc/systemd/system/wangka-led.service
sudo install -m 0755 ${STAGE}/wangka-management-proxy /usr/local/sbin/wangka-management-proxy
sudo systemctl daemon-reload
sudo systemctl enable --now wangka-led.service
sudo systemctl restart wangka-web-proxy.service
sudo systemctl is-active wangka-led.service wangka-web-proxy.socket wangka-web-proxy.service
sudo /usr/local/sbin/wangka-led apply >/dev/null
sudo test -s /run/wangka-led/status.json
sudo /usr/local/sbin/wangka-led status"

printf 'LED_DEPLOY=PASS\n'
