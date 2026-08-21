#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CREDENTIAL_FILE=${PROJECT_ROOT}/private/device-credentials.env
TOKEN_FILE=${PROJECT_ROOT}/private/host-uplink.secret
STAGE=/tmp/wangka-batch2
PAIRING_CONFIG=/private/tmp/wangka-host-uplink.json

[ -f "${CREDENTIAL_FILE}" ] || { printf 'FAIL: missing %s\n' "${CREDENTIAL_FILE}" >&2; exit 1; }
set -a
. "${CREDENTIAL_FILE}"
set +a
[ -n "${WANGKA_USER_PASSWORD:-}" ] || { printf 'FAIL: private SSH password is empty\n' >&2; exit 1; }

if [ ! -f "${TOKEN_FILE}" ]; then
    umask 077
    /usr/bin/openssl rand -hex 32 > "${TOKEN_FILE}"
fi
TOKEN=$(tr -d '\r\n' < "${TOKEN_FILE}")
case "${TOKEN}" in *[!a-f0-9]*|'') printf 'FAIL: invalid private token\n' >&2; exit 1 ;; esac
[ "${#TOKEN}" -eq 64 ] || { printf 'FAIL: invalid private token length\n' >&2; exit 1; }

if [ "${WANGKA_SKIP_MAC_INSTALL:-0}" != 1 ]; then
    "${PROJECT_ROOT}/scripts/install_macos_host_uplink.sh" "${TOKEN_FILE}"
fi

umask 077
printf '{"helper_url":"http://192.168.5.242:19531","token":"%s"}\n' "${TOKEN}" \
    > "${PAIRING_CONFIG}"
trap 'rm -f "${PAIRING_CONFIG}"' EXIT INT TERM

"${PROJECT_ROOT}/scripts/ssh-run.expect" \
    "sudo install -d -o user -g user -m 0700 ${STAGE}"

upload() {
    "${PROJECT_ROOT}/scripts/scp-to-device.expect" "$1" "${STAGE}/$2"
}

upload "${PROJECT_ROOT}/config/network/wangka-uplink-manager.py" wangka-uplink
upload "${PROJECT_ROOT}/config/network/resolv.conf.device-uplink" resolv.conf
upload "${PROJECT_ROOT}/config/network/wangka-host-uplink.nft" wangka-host-uplink.nft
upload "${PROJECT_ROOT}/config/network/wangka-uplink-reconcile.service" wangka-uplink-reconcile.service
upload "${PROJECT_ROOT}/config/network/wangka-uplink-reconcile.timer" wangka-uplink-reconcile.timer
upload "${PROJECT_ROOT}/config/vohive/wangka-management-proxy.py" wangka-management-proxy
upload "${PROJECT_ROOT}/config/vohive/wangka-web-proxy.socket" wangka-web-proxy.socket
upload "${PAIRING_CONFIG}" host-uplink.json

"${PROJECT_ROOT}/scripts/ssh-run.expect" "set -eu
sudo install -d -m 0700 /etc/wangka /var/lib/wangka-management
sudo install -d -m 0755 /var/lib/wangka-network
sudo install -d -m 0755 /etc/nftables.d /usr/local/sbin
sudo install -m 0755 ${STAGE}/wangka-uplink /usr/local/sbin/wangka-uplink
sudo install -m 0644 ${STAGE}/resolv.conf /var/lib/wangka-network/resolv.conf
sudo ln -sfn /var/lib/wangka-network/resolv.conf /etc/resolv.conf
sudo install -m 0644 ${STAGE}/wangka-host-uplink.nft /etc/nftables.d/wangka-host-uplink.nft
sudo install -m 0600 ${STAGE}/host-uplink.json /etc/wangka/host-uplink.json
sudo install -m 0644 ${STAGE}/wangka-uplink-reconcile.service /etc/systemd/system/wangka-uplink-reconcile.service
sudo install -m 0644 ${STAGE}/wangka-uplink-reconcile.timer /etc/systemd/system/wangka-uplink-reconcile.timer
sudo install -m 0755 ${STAGE}/wangka-management-proxy /usr/local/sbin/wangka-management-proxy
sudo install -m 0644 ${STAGE}/wangka-web-proxy.socket /etc/systemd/system/wangka-web-proxy.socket
sudo systemctl daemon-reload
sudo systemctl enable --now wangka-uplink-reconcile.timer
sudo /usr/local/sbin/wangka-uplink device-uplink
sudo systemctl stop wangka-web-proxy.service || true
sudo systemctl restart wangka-web-proxy.socket
sudo systemctl is-active wangka-web-proxy.socket vohive.service wangka-uplink-reconcile.timer
sudo /usr/local/sbin/wangka-uplink status"

printf 'BATCH2_DEPLOY=PASS\n'
printf 'PAIRING_TOKEN=SET_AND_REDACTED\n'
