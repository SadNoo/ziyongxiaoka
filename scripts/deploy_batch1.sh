#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
STAGE=/tmp/wangka-batch1
VOHIVE_BINARY=${PROJECT_ROOT}/vendor/vohive/vohive_v1.5.5-10-gf9eb85d_linux_arm64
EXPECTED_SHA256=4cbfcec06b719609f3d88714b4df63c420e1cf958fbad0b4851a3c495c595661
RENDERED_CONFIG=/private/tmp/wangka-vohive-default.yaml
TRUSTED_EPOCH=$(date -u +%s)

[ -f "${PROJECT_ROOT}/.env" ] || { echo "missing private .env" >&2; exit 1; }
set -a
. "${PROJECT_ROOT}/.env"
set +a

actual=$(shasum -a 256 "${VOHIVE_BINARY}" | awk '{print $1}')
[ "${actual}" = "${EXPECTED_SHA256}" ] || { echo "VoHive asset hash mismatch" >&2; exit 1; }

"${PROJECT_ROOT}/scripts/render_vohive_config.sh" \
    "${PROJECT_ROOT}/config/wangka-defaults.env" "${RENDERED_CONFIG}" >/dev/null

"${PROJECT_ROOT}/scripts/ssh-run.expect" \
    "sudo install -d -o user -g user -m 0700 ${STAGE}"

upload() {
    "${PROJECT_ROOT}/scripts/scp-to-device.expect" "$1" "${STAGE}/$2"
}

upload "${VOHIVE_BINARY}" vohive
upload "${RENDERED_CONFIG}" vohive-default.yaml
upload "${PROJECT_ROOT}/config/vohive/vohive.service" vohive.service
upload "${PROJECT_ROOT}/config/vohive/wangka-vohive-enroll.py" wangka-vohive-enroll
upload "${PROJECT_ROOT}/config/vohive/wangka-vohive-enroll.service" wangka-vohive-enroll.service
upload "${PROJECT_ROOT}/config/vohive/wangka-web-firewall.service" wangka-web-firewall.service
upload "${PROJECT_ROOT}/config/vohive/wangka-web-proxy.socket" wangka-web-proxy.socket
upload "${PROJECT_ROOT}/config/vohive/wangka-web-proxy.service" wangka-web-proxy.service
upload "${PROJECT_ROOT}/config/vohive/wangka-web.nft" wangka-web.nft
upload "${PROJECT_ROOT}/config/vohive/wangka-management-proxy.py" wangka-management-proxy
upload "${PROJECT_ROOT}/config/vohive/wangka-vohive-maintenance.sh" wangka-vohive
upload "${PROJECT_ROOT}/config/network/wangka-network-ready.sh" wangka-network-ready
upload "${PROJECT_ROOT}/config/network/wangka-network-ready.service" wangka-network-ready.service
upload "${PROJECT_ROOT}/config/time/wangka-timekeeper.sh" wangka-timekeeper
upload "${PROJECT_ROOT}/config/time/wangka-timekeeper.service" wangka-timekeeper.service
upload "${PROJECT_ROOT}/config/time/wangka-timekeeper-save.service" wangka-timekeeper-save.service
upload "${PROJECT_ROOT}/config/time/wangka-timekeeper.timer" wangka-timekeeper.timer

"${PROJECT_ROOT}/scripts/ssh-run.expect" "set -eu
printf '${EXPECTED_SHA256}  ${STAGE}/vohive\n' | sha256sum -c -
sudo systemctl stop wangka-web-proxy.socket wangka-web-proxy.service vohive.service || true
sudo install -d -m 0700 /etc/vohive /var/lib/vohive/data /var/lib/vohive/logs /var/lib/wangka-management
sudo install -d -m 0755 /etc/nftables.d /usr/lib/wangka /usr/local/sbin
sudo install -m 0755 ${STAGE}/vohive /usr/local/sbin/vohive
sudo install -m 0755 ${STAGE}/vohive /usr/lib/wangka/vohive
sudo install -m 0600 ${STAGE}/vohive-default.yaml /usr/lib/wangka/vohive-default.yaml
if ! sudo test -f /etc/vohive/config.yaml; then sudo install -m 0600 ${STAGE}/vohive-default.yaml /etc/vohive/config.yaml; fi
sudo install -m 0755 ${STAGE}/wangka-vohive-enroll /usr/local/sbin/wangka-vohive-enroll
sudo install -m 0755 ${STAGE}/wangka-management-proxy /usr/local/sbin/wangka-management-proxy
sudo install -m 0755 ${STAGE}/wangka-vohive /usr/local/sbin/wangka-vohive
sudo install -m 0755 ${STAGE}/wangka-network-ready /usr/local/sbin/wangka-network-ready
sudo install -m 0644 ${STAGE}/wangka-network-ready.service /etc/systemd/system/wangka-network-ready.service
sudo install -m 0755 ${STAGE}/wangka-timekeeper /usr/local/sbin/wangka-timekeeper
for unit in wangka-timekeeper.service wangka-timekeeper-save.service wangka-timekeeper.timer; do sudo install -m 0644 ${STAGE}/\$unit /etc/systemd/system/\$unit; done
printf '%s\n' '${TRUSTED_EPOCH}' | sudo tee /usr/lib/wangka/build-epoch >/dev/null
sudo chmod 0644 /usr/lib/wangka/build-epoch
sudo install -m 0644 ${STAGE}/wangka-web.nft /etc/nftables.d/wangka-web.nft
for unit in vohive.service wangka-vohive-enroll.service wangka-web-firewall.service wangka-web-proxy.socket wangka-web-proxy.service; do sudo install -m 0644 ${STAGE}/\$unit /etc/systemd/system/\$unit; done
if ! sudo test -f /var/lib/wangka-management/state.json; then printf '%s\n' '{\"generation\": 0, \"initialized\": false, \"uplink_mode\": \"device-uplink\"}' | sudo tee /var/lib/wangka-management/state.json >/dev/null; sudo chmod 0600 /var/lib/wangka-management/state.json; fi
sudo systemctl daemon-reload
sudo systemctl enable wangka-network-ready.service
sudo systemctl enable wangka-timekeeper.service wangka-timekeeper.timer
sudo systemctl start wangka-timekeeper.service wangka-timekeeper.timer
sudo timedatectl set-timezone ${WANGKA_TIMEZONE}
sudo /usr/local/sbin/wangka-vohive repair
printf 'user:123456789\n' | sudo chpasswd
sudo nmcli connection modify hotspot 802-11-wireless-security.psk 123456789
sudo nmcli connection down hotspot || true
sudo nmcli connection up hotspot
sudo systemctl restart wangka-network-ready.service
sudo /usr/local/sbin/wangka-vohive status"

echo 'BATCH1_LIVE_DEPLOY=PASS'
echo 'MANAGEMENT_NETWORK_RETRY=INSTALLED'
