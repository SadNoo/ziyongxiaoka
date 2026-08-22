#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CREDENTIAL_FILE=${PROJECT_ROOT}/private/device-credentials.env
STAGE=/tmp/wangka-batch3
APN=${WANGKA_APN:-}
VOHIVE_BINARY=${PROJECT_ROOT}/private/build/vohive_v1.5.5-wangka1_linux_arm64
VOHIVE_SHA256=1a624e443e1b96fee4083db91937398a95a9c75f8e32675c5eded036139c614a

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
if [ -n "${APN}" ]; then
    case "${APN}" in
        *[!A-Za-z0-9.-]*) printf 'FAIL: invalid APN\n' >&2; exit 1 ;;
    esac
    [ "${#APN}" -le 100 ] || { printf 'FAIL: APN is too long\n' >&2; exit 1; }
fi
[ -f "${VOHIVE_BINARY}" ] || { printf 'FAIL: patched VoHive binary is missing\n' >&2; exit 1; }
[ "$(shasum -a 256 "${VOHIVE_BINARY}" | awk '{print $1}')" = "${VOHIVE_SHA256}" ] \
    || { printf 'FAIL: patched VoHive hash mismatch\n' >&2; exit 1; }

"${PROJECT_ROOT}/scripts/ssh-run.expect" \
    "sudo install -d -o user -g user -m 0700 ${STAGE}"

upload() {
    "${PROJECT_ROOT}/scripts/scp-to-device.expect" "$1" "${STAGE}/$2"
}

upload "${PROJECT_ROOT}/config/vohive/wangka-vohive-qmi-owner.py" wangka-vohive-qmi-owner
upload "${PROJECT_ROOT}/config/vohive/wangka-vohive-enroll.py" wangka-vohive-enroll
upload "${PROJECT_ROOT}/config/vohive/vohive.service" vohive.service
upload "${PROJECT_ROOT}/config/network/wangka-uplink-manager.py" wangka-uplink
upload "${PROJECT_ROOT}/config/network/wangka-network-ready.sh" wangka-network-ready
upload "${PROJECT_ROOT}/config/network/wangka-network-ready.service" wangka-network-ready.service
upload "${PROJECT_ROOT}/config/network/wangka-modem.py" wangka-modem
upload "${PROJECT_ROOT}/config/vohive/wangka-management-proxy.py" wangka-management-proxy
upload "${PROJECT_ROOT}/config/vohive/wangka-web-proxy.socket" wangka-web-proxy.socket
upload "${PROJECT_ROOT}/config/network/wangka-work-mode.py" wangka-work-mode
upload "${PROJECT_ROOT}/config/network/wangka-uplink-reconcile.service" wangka-uplink-reconcile.service
upload "${VOHIVE_BINARY}" vohive

"${PROJECT_ROOT}/scripts/ssh-run.expect" "set -eu
sudo systemctl stop wangka-vohive-enroll.service vohive.service
sudo systemctl stop wangka-network-ready.service
sudo systemctl stop wangka-web-proxy.service wangka-web-proxy.socket
sudo install -d -m 0700 /var/lib/wangka-management/batch3-rollback
if [ ! -f /var/lib/wangka-management/batch3-rollback/config.yaml ]; then
    sudo install -m 0600 /etc/vohive/config.yaml /var/lib/wangka-management/batch3-rollback/config.yaml
fi
if [ ! -f /var/lib/wangka-management/batch3-rollback/vohive ]; then
    sudo install -m 0755 /usr/local/sbin/vohive /var/lib/wangka-management/batch3-rollback/vohive
fi
sudo install -m 0755 ${STAGE}/wangka-vohive-qmi-owner /usr/local/sbin/wangka-vohive-qmi-owner
sudo install -m 0755 ${STAGE}/wangka-vohive-enroll /usr/local/sbin/wangka-vohive-enroll
sudo install -m 0644 ${STAGE}/vohive.service /etc/systemd/system/vohive.service
sudo install -m 0755 ${STAGE}/wangka-uplink /usr/local/sbin/wangka-uplink
sudo install -m 0755 ${STAGE}/wangka-network-ready /usr/local/sbin/wangka-network-ready
sudo install -m 0644 ${STAGE}/wangka-network-ready.service /etc/systemd/system/wangka-network-ready.service
sudo install -m 0755 ${STAGE}/wangka-modem /usr/local/sbin/wangka-modem
sudo install -m 0755 ${STAGE}/wangka-management-proxy /usr/local/sbin/wangka-management-proxy
sudo install -m 0644 ${STAGE}/wangka-web-proxy.socket /etc/systemd/system/wangka-web-proxy.socket
sudo install -m 0755 ${STAGE}/wangka-work-mode /usr/local/sbin/wangka-work-mode
sudo install -m 0644 ${STAGE}/wangka-uplink-reconcile.service /etc/systemd/system/wangka-uplink-reconcile.service
sudo install -m 0755 ${STAGE}/vohive /usr/local/sbin/vohive
sudo install -m 0755 ${STAGE}/vohive /usr/lib/wangka/vohive
sudo systemctl disable --now ModemManager.service || true
sudo systemctl mask ModemManager.service
sudo /usr/local/sbin/wangka-vohive-qmi-owner
sudo systemctl daemon-reload
sudo systemctl start wangka-web-proxy.socket
sudo systemctl restart wangka-network-ready.service
sudo systemctl restart wangka-uplink-reconcile.timer
sudo systemctl restart vohive.service
sudo systemctl restart wangka-vohive-enroll.service
sudo systemctl is-active NetworkManager.service wangka-network-ready.service vohive.service wangka-vohive-enroll.service wangka-web-proxy.socket wangka-uplink-reconcile.timer
test \"\$(sudo systemctl is-enabled ModemManager.service)\" = masked
sleep 15
if [ -n '${APN}' ]; then
    sudo /usr/local/sbin/wangka-modem data-connect '${APN}' >/dev/null
else
    sudo /usr/local/sbin/wangka-modem reconnect-saved-uplink >/dev/null
fi
sudo /usr/local/sbin/wangka-uplink reconcile >/dev/null
curl -sS --max-time 10 -o /dev/null http://192.168.5.1/
sudo systemctl is-active wangka-web-proxy.service
sudo test \"\$(readlink -f /etc/resolv.conf)\" = /var/lib/wangka-network/resolv.conf
sudo grep -q '^ExecStartPre=/usr/local/sbin/wangka-vohive-qmi-owner$' /etc/systemd/system/vohive.service
sudo grep -q '^Conflicts=ModemManager.service$' /etc/systemd/system/vohive.service
sudo grep -q 'device_backend: qmi' /etc/vohive/config.yaml
sudo grep -q '/api/devices/{DEVICE_ID}/network' /usr/local/sbin/wangka-modem
test \"\$(sudo stat -c '%a' /var/lib/wangka-management/vohive-local-auth.json)\" = 600
ip -4 route show default | grep -q ' dev wwan0 '
sudo /usr/local/sbin/wangka-modem status >/dev/null
sudo /usr/local/sbin/wangka-modem sms-list >/dev/null
sudo /usr/local/sbin/wangka-work-mode status >/dev/null
sudo sha256sum /usr/local/sbin/vohive | grep -q '^${VOHIVE_SHA256} '"

printf 'BATCH3_DEPLOY=PASS\n'
printf 'QMI_OWNER=VOHIVE\n'
