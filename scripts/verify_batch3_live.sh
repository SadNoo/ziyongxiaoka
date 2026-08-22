#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CREDENTIAL_FILE=${PROJECT_ROOT}/private/device-credentials.env
OBSERVE_SECONDS=${WANGKA_BATCH3_OBSERVE_SECONDS:-1800}
POLL_SECONDS=${WANGKA_BATCH3_POLL_SECONDS:-30}

[ -f "${CREDENTIAL_FILE}" ] || {
    printf 'FAIL: missing private credentials\n' >&2
    exit 1
}
set -a
. "${CREDENTIAL_FILE}"
set +a

case "${OBSERVE_SECONDS}:${POLL_SECONDS}" in
    *[!0-9:]*|0:*|*:0) printf 'FAIL: invalid observation duration\n' >&2; exit 1 ;;
esac

start=$(date +%s)
deadline=$((start + OBSERVE_SECONDS))
samples=0
while [ "$(date +%s)" -lt "${deadline}" ]; do
    "${PROJECT_ROOT}/scripts/ssh-run.expect" "set -eu
sudo systemctl is-active --quiet NetworkManager.service wangka-network-ready.service wangka-web-firewall.service vohive.service wangka-web-proxy.socket
test \"\$(sudo systemctl is-enabled ModemManager.service)\" = masked
! pgrep -x ModemManager >/dev/null
test \"\$(sudo stat -c '%a' /var/lib/wangka-management/vohive-local-auth.json)\" = 600
ip -4 route show default | grep -q ' dev wwan0 '
getent ahostsv4 baidu.com >/dev/null
curl -L -sS --max-time 15 -o /dev/null https://www.baidu.com
curl -sS --max-time 10 -o /dev/null http://192.168.5.1/
curl -sS --max-time 10 -o /dev/null http://192.168.4.1/
sudo systemctl is-active --quiet wangka-web-proxy.service
nmcli -t -f NAME connection show --active | grep -Fxq hotspot
sudo /usr/local/sbin/wangka-modem status >/dev/null
sudo /usr/local/sbin/wangka-modem sms-list >/dev/null
test \"\$(sudo journalctl -u vohive.service --since '@${start}' -o cat --no-pager | grep -Ec 'Timeout storm|qmi_transport_down|Modem reset detected|QMI 连接断开' || true)\" -eq 0"
    samples=$((samples + 1))
    now=$(date +%s)
    [ "${now}" -ge "${deadline}" ] && break
    sleep "${POLL_SECONDS}"
done

printf 'BATCH3_STABILITY=PASS\n'
printf 'OBSERVE_SECONDS=%s\n' "${OBSERVE_SECONDS}"
printf 'SAMPLES=%s\n' "${samples}"
