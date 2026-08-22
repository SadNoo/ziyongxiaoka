#!/bin/sh
set -eu

MAX_ATTEMPTS=${WANGKA_NETWORK_ATTEMPTS:-3}

is_active() {
    /usr/bin/nmcli -t -f NAME connection show --active 2>/dev/null \
        | grep -Fxq "$1"
}

attempt=1
while [ "${attempt}" -le "${MAX_ATTEMPTS}" ]; do
    if ! is_active usb; then
        /usr/bin/nmcli --wait 8 connection up usb >/dev/null 2>&1 || true
    fi
    if ! is_active hotspot; then
        /usr/bin/nmcli --wait 8 connection up hotspot >/dev/null 2>&1 || true
    fi
    if is_active usb && is_active hotspot; then
        printf 'WANGKA_NETWORK_READY=PASS\n'
        exit 0
    fi
    attempt=$((attempt + 1))
    sleep 2
done

if is_active usb; then
    # Keep USB administration, VoHive and LTE available even when the Wi-Fi
    # firmware or radio is temporarily unavailable.  The reconcile timer
    # continues retrying the hotspot after the rest of the stack has started.
    printf 'WANGKA_NETWORK_READY=PASS:USB_ONLY\n'
    exit 0
fi

printf 'WANGKA_NETWORK_READY=FAIL\n' >&2
exit 1
