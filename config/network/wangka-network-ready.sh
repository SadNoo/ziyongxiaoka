#!/bin/sh
set -eu

MAX_ATTEMPTS=${WANGKA_NETWORK_ATTEMPTS:-12}

is_active() {
    /usr/bin/nmcli -t -f NAME connection show --active 2>/dev/null \
        | grep -Fxq "$1"
}

attempt=1
while [ "${attempt}" -le "${MAX_ATTEMPTS}" ]; do
    if ! is_active usb; then
        /usr/bin/nmcli --wait 12 connection up usb >/dev/null 2>&1 || true
    fi
    if ! is_active hotspot; then
        /usr/bin/nmcli --wait 15 connection up hotspot >/dev/null 2>&1 || true
    fi
    if is_active usb && is_active hotspot; then
        printf 'WANGKA_NETWORK_READY=PASS\n'
        exit 0
    fi
    attempt=$((attempt + 1))
    sleep 3
done

/usr/bin/nmcli device status >&2 || true
/usr/bin/nmcli connection show --active >&2 || true
printf 'WANGKA_NETWORK_READY=FAIL\n' >&2
exit 1
