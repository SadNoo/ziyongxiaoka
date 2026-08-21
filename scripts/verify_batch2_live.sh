#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CREDENTIAL_FILE=${PROJECT_ROOT}/private/device-credentials.env
BASE_URL=${WANGKA_BASE_URL:-http://192.168.5.1}
TMP_DIR=$(mktemp -d /private/tmp/wangka-batch2-verify.XXXXXX)
trap 'rm -rf "${TMP_DIR}"' EXIT HUP INT TERM

[ -f "${CREDENTIAL_FILE}" ] || { printf 'FAIL: missing private credentials\n' >&2; exit 1; }
set -a
. "${CREDENTIAL_FILE}"
set +a

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

for endpoint in "${BASE_URL}" "${BASE_URL}:7575"; do
    code=$(curl -sS --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' "${endpoint}/")
    [ "${code}" = 200 ] || fail "management endpoint ${endpoint} returned HTTP ${code}"
done
pass 'USB HTTP 80/7575'

payload=$(jq -cn --arg username user --arg password "${WANGKA_USER_PASSWORD}" \
    '{username:$username,password:$password}')
curl -sS --connect-timeout 5 --max-time 15 \
    -H 'Content-Type: application/json' --data "${payload}" \
    "${BASE_URL}/api/auth/login" > "${TMP_DIR}/login.json"
TOKEN=$(jq -r '.token // empty' "${TMP_DIR}/login.json")
[ -n "${TOKEN}" ] || fail 'VoHive login'
curl -sS --connect-timeout 5 --max-time 15 \
    -H "Authorization: Bearer ${TOKEN}" \
    "${BASE_URL}/wangka/api/status" > "${TMP_DIR}/status.json"
jq -e '
    .uplink_mode == "host-uplink" and
    .host_uplink_installed == true and
    .uplink.helper_reachable == true and
    .uplink.helper_enabled == true and
    (.uplink.last_result == "ok" or .uplink.last_result == "renewed")
' "${TMP_DIR}/status.json" >/dev/null || fail 'VoHive host-uplink status'
pass 'VoHive host-uplink status'

"${PROJECT_ROOT}/scripts/ssh-run.expect" "set -eu
ip -4 route show default | grep -q 'default via 192.168.5.242 dev usb0 metric 50'
[ \"\$(readlink /etc/resolv.conf)\" = /var/lib/wangka-network/resolv.conf ]
grep -q 'Managed by wangka-uplink (macOS host-uplink)' /etc/resolv.conf
sudo nft list table inet wangka_host_uplink | grep -q 'iifname \"wlan0\" oifname \"usb0\" drop'
getent ahostsv4 deb.debian.org >/dev/null
python3 -c \"import urllib.request; assert urllib.request.urlopen('https://deb.debian.org/', timeout=15).status == 200\""
pass 'Debian route, atomic DNS, Wi-Fi isolation and HTTPS'

USB_INTERFACE=$(networksetup -listallhardwareports | awk '
    $0 == "Hardware Port: UFI103S Debian ECM" { getline; print $2; exit }
')
[ -n "${USB_INTERFACE}" ] || fail 'Mac USB network service'
DEFAULT_INTERFACE=$(route -n get default | awk '/interface:/{print $2; exit}')
[ "${DEFAULT_INTERFACE}" != "${USB_INTERFACE}" ] || fail 'USB incorrectly became Mac default route'
networksetup -getinfo 'UFI103S Debian ECM' > "${TMP_DIR}/usb-info.txt"
grep -q '^IP address: 192.168.5.242$' "${TMP_DIR}/usb-info.txt" || fail 'Mac USB address'
grep -q '^Router: 0.0.0.0$' "${TMP_DIR}/usb-info.txt" || fail 'Mac USB router is not empty'
pass 'Mac default route and static USB service'

printf 'BATCH2_LIVE_VERIFY=PASS\n'
