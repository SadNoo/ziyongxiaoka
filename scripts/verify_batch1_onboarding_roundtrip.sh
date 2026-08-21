#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BASE_URL=${WANGKA_BASE_URL:-http://192.168.5.1}
TMP_DIR=$(mktemp -d /private/tmp/wangka-onboarding-verify.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

set -a
. "${PROJECT_ROOT}/.env"
set +a

fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

login() {
    curl -sS --connect-timeout 5 --max-time 15 \
        -H 'Content-Type: application/json' \
        --data "{\"username\":\"${WANGKA_VOHIVE_USERNAME}\",\"password\":\"${WANGKA_VOHIVE_PASSWORD}\"}" \
        "${BASE_URL}/api/auth/login" | jq -r '.token // empty'
}

TOKEN=$(login)
[ -n "$TOKEN" ] || fail 'factory login'

payload=$(jq -cn \
    --arg password "$WANGKA_VOHIVE_PASSWORD" \
    --arg ssid 'Wangka-UFI103S' \
    '{targets:["ssh","wifi","vohive"],new_password:$password,confirm_password:$password,current_vohive_password:$password,wifi_ssid:$ssid}')
code=$(curl -sS --connect-timeout 5 --max-time 30 \
    -o "$TMP_DIR/apply.json" -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${TOKEN}" --data "$payload" \
    "${BASE_URL}/wangka/api/credentials")
[ "$code" = 200 ] || fail "credential apply HTTP ${code}"
jq -e '.status == "ok" and .initialized == true' "$TMP_DIR/apply.json" >/dev/null \
    || fail 'credential apply response'
printf 'PASS credential apply across SSH, Wi-Fi and VoHive\n'

sleep 5
TOKEN=$(login)
[ -n "$TOKEN" ] || fail 'login after credential apply'
curl -sS --connect-timeout 5 --max-time 15 \
    -H "Authorization: Bearer ${TOKEN}" \
    "${BASE_URL}/wangka/api/status" >"$TMP_DIR/status.json"
jq -e '.initialized == true and .generation >= 1' "$TMP_DIR/status.json" >/dev/null \
    || fail 'initialized state'
printf 'PASS initialized state and post-change login\n'

code=$(curl -sS --connect-timeout 5 --max-time 15 \
    -o "$TMP_DIR/devices.json" -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" "${BASE_URL}/api/devices")
[ "$code" != 428 ] || fail 'VoHive API remained gated after onboarding'
printf 'PASS VoHive API gate released after onboarding\n'

# Restore the factory hand-off state without changing the verified credentials.
"${PROJECT_ROOT}/scripts/ssh-run.expect" \
    "printf '%s\\n' '{\"generation\": 0, \"initialized\": false, \"uplink_mode\": \"device-uplink\"}' | sudo tee /var/lib/wangka-management/state.json >/dev/null; sudo chmod 0600 /var/lib/wangka-management/state.json"

TOKEN=$(login)
[ -n "$TOKEN" ] || fail 'factory login after reset'
curl -sS --connect-timeout 5 --max-time 15 \
    -H "Authorization: Bearer ${TOKEN}" \
    "${BASE_URL}/wangka/api/status" >"$TMP_DIR/reset-status.json"
jq -e '.initialized == false and .generation == 0' "$TMP_DIR/reset-status.json" >/dev/null \
    || fail 'factory hand-off state reset'
printf 'PASS factory hand-off state restored\n'
printf 'BATCH1_ONBOARDING_ROUNDTRIP=PASS\n'
