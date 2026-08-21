#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BASE_URL=${WANGKA_BASE_URL:-http://192.168.5.1}
ALT_URL=${WANGKA_ALT_URL:-http://192.168.5.1:7575}
RAW_URL=${WANGKA_RAW_URL:-http://192.168.5.1:17575}
TMP_DIR=$(mktemp -d /private/tmp/wangka-live-verify.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

set -a
. "${PROJECT_ROOT}/.env"
set +a

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
http_code() {
    curl -sS --connect-timeout 5 --max-time 15 -o "$1" -w '%{http_code}' "$2"
}

code=$(http_code "$TMP_DIR/root.html" "${BASE_URL}/")
[ "$code" = 200 ] || fail "USB root HTTP ${code}"
grep -q 'wangka-shell-script' "$TMP_DIR/root.html" || fail 'protected shell injection missing'
pass 'USB root and protected shell injection'

code=$(http_code "$TMP_DIR/system.html" "${BASE_URL}/wangka/system-device")
[ "$code" = 200 ] || fail "system-device HTTP ${code}"
grep -q '系统设备' "$TMP_DIR/system.html" || fail 'system-device content missing'
grep -q '切换到 Mac 上行' "$TMP_DIR/system.html" || fail 'uplink controls missing'
pass 'system-device page and uplink controls'

for endpoint in "${BASE_URL}" "${ALT_URL}"; do
    code=$(curl -sS --connect-timeout 5 --max-time 15 \
        -o "$TMP_DIR/uninstall.json" -w '%{http_code}' \
        -X POST "${endpoint}/api/system/uninstall")
    [ "$code" = 403 ] || fail "uninstall was not blocked at ${endpoint} (HTTP ${code})"
done
pass 'uninstall blocked on ports 80 and 7575'

if curl -sS --connect-timeout 2 --max-time 3 -o /dev/null "$RAW_URL/" 2>/dev/null; then
    fail 'raw backend is externally reachable'
fi
pass 'raw backend port 17575 blocked externally'

login_code=$(curl -sS --connect-timeout 5 --max-time 15 \
    -o "$TMP_DIR/login.json" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    --data "{\"username\":\"${WANGKA_VOHIVE_USERNAME}\",\"password\":\"${WANGKA_VOHIVE_PASSWORD}\"}" \
    "${BASE_URL}/api/auth/login")
[ "$login_code" = 200 ] || fail "VoHive login HTTP ${login_code}"
TOKEN=$(jq -r '.token // empty' "$TMP_DIR/login.json")
[ -n "$TOKEN" ] || fail 'VoHive login token missing'
pass 'VoHive factory login'

status_code=$(curl -sS --connect-timeout 5 --max-time 15 \
    -o "$TMP_DIR/status.json" -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" "${BASE_URL}/wangka/api/status")
[ "$status_code" = 200 ] || fail "management status HTTP ${status_code}"
jq -e '.initialized == false and .uninstall_blocked == true and .vohive_active == true and .host_uplink_installed == false' \
    "$TMP_DIR/status.json" >/dev/null || fail 'management status policy mismatch'
pass 'first-use gate and live service status'

host_epoch=$(date -u +%s)
code=$(curl -sS --connect-timeout 5 --max-time 15 \
    -o "$TMP_DIR/time.json" -w '%{http_code}' \
    -X POST -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    --data "{\"client_epoch\":${host_epoch},\"timezone\":\"Asia/Shanghai\"}" \
    "${BASE_URL}/wangka/api/time")
[ "$code" = 200 ] || fail "time synchronization HTTP ${code}"
device_epoch=$(jq -r '.system_epoch' "$TMP_DIR/time.json")
time_delta=$((device_epoch - host_epoch))
[ "$time_delta" -lt 0 ] && time_delta=$((-time_delta))
[ "$time_delta" -le 5 ] || fail "device time differs from host by ${time_delta}s"
jq -e '.timezone == "Asia/Shanghai" and .persistent_clock == true' \
    "$TMP_DIR/time.json" >/dev/null || {
        observed=$(jq -c '{timezone, persistent_clock}' "$TMP_DIR/time.json")
        fail "persistent time policy mismatch: ${observed}"
    }
pass 'browser-assisted time sync and persistent clock'

code=$(curl -sS --connect-timeout 5 --max-time 15 \
    -o "$TMP_DIR/gated.json" -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" "${BASE_URL}/api/devices")
[ "$code" = 428 ] || fail "first-use API gate HTTP ${code}"
pass 'VoHive APIs gated until credential initialization'

code=$(curl -sS --connect-timeout 5 --max-time 15 \
    -o "$TMP_DIR/generated.json" -w '%{http_code}' \
    -X POST -H "Authorization: Bearer ${TOKEN}" "${BASE_URL}/wangka/api/generate")
[ "$code" = 200 ] || fail "password generation HTTP ${code}"
generated_length=$(jq -r '.password | length' "$TMP_DIR/generated.json")
[ "$generated_length" -ge 20 ] || fail 'generated password is too short'
pass 'password generation endpoint (secret not printed)'

printf 'BATCH1_LIVE_VERIFY=PASS\n'
