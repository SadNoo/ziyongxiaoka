#!/bin/sh
set -eu

COMMAND=${1:-status}
CANONICAL_BINARY=/usr/lib/wangka/vohive
CANONICAL_CONFIG=/usr/lib/wangka/vohive-default.yaml
LIVE_BINARY=/usr/local/sbin/vohive
LIVE_CONFIG=/etc/vohive/config.yaml
EXPECTED_SHA256=1a624e443e1b96fee4083db91937398a95a9c75f8e32675c5eded036139c614a

require_root() {
    [ "$(id -u)" -eq 0 ] || {
        echo "run with sudo" >&2
        exit 1
    }
}

binary_ok() {
    [ -f "$LIVE_BINARY" ] || return 1
    [ "$(sha256sum "$LIVE_BINARY" | awk '{print $1}')" = "$EXPECTED_SHA256" ]
}

case "$COMMAND" in
    status)
        if binary_ok; then echo 'VOHIVE_BINARY=PASS'; else echo 'VOHIVE_BINARY=FAIL'; fi
        if [ -f "$LIVE_CONFIG" ]; then echo 'VOHIVE_CONFIG=PRESENT'; else echo 'VOHIVE_CONFIG=MISSING'; fi
        printf 'VOHIVE_SERVICE=%s\n' "$(systemctl is-active vohive.service 2>/dev/null || true)"
        printf 'MANAGEMENT_SOCKET=%s\n' "$(systemctl is-active wangka-web-proxy.socket 2>/dev/null || true)"
        printf 'ONBOARD_MODEM_ENROLL=%s\n' "$(systemctl is-active wangka-vohive-enroll.service 2>/dev/null || true)"
        printf 'TIMEKEEPER=%s\n' "$(systemctl is-active wangka-timekeeper.service 2>/dev/null || true)"
        printf 'SYSTEM_TIME=%s\n' "$(date --iso-8601=seconds)"
        if grep -q '"initialized": true' /var/lib/wangka-management/state.json 2>/dev/null; then
            echo 'ONBOARDING=COMPLETE'
        else
            echo 'ONBOARDING=REQUIRED'
        fi
        ;;
    repair)
        require_root
        printf '%s  %s\n' "$EXPECTED_SHA256" "$CANONICAL_BINARY" | sha256sum -c -
        install -d -m 0700 /etc/vohive /var/lib/vohive/data /var/lib/vohive/logs /var/lib/wangka-management
        if ! binary_ok; then
            install -m 0755 "$CANONICAL_BINARY" "$LIVE_BINARY"
        fi
        if [ ! -f "$LIVE_CONFIG" ]; then
            install -m 0600 "$CANONICAL_CONFIG" "$LIVE_CONFIG"
            printf '%s\n' '{"access_mode":"login-required","generation":0,"initialized":false,"led_enabled":true,"led_night_mode":false,"uplink_mode":"device-uplink","work_mode":"dual"}' \
                > /var/lib/wangka-management/state.json
            chmod 0600 /var/lib/wangka-management/state.json
        fi
        systemctl daemon-reload
        systemctl enable wangka-timekeeper.service wangka-timekeeper.timer wangka-network-ready.service wangka-web-firewall.service wangka-web-proxy.socket wangka-led.service vohive.service wangka-vohive-enroll.service
        systemctl start wangka-timekeeper.service wangka-timekeeper.timer
        systemctl restart wangka-network-ready.service
        systemctl restart wangka-web-firewall.service
        systemctl restart vohive.service
        systemctl restart wangka-led.service
        systemctl restart wangka-web-proxy.socket
        # Modem enrollment may legitimately use its full 180-second timeout
        # when no SIM is installed.  Repair must return promptly while the
        # oneshot continues under systemd supervision.
        systemctl restart --no-block wangka-vohive-enroll.service
        echo 'VOHIVE_REPAIR=PASS'
        ;;
    reenroll)
        require_root
        systemctl restart wangka-vohive-enroll.service
        systemctl is-active --quiet wangka-vohive-enroll.service
        echo 'VOHIVE_REENROLL=PASS'
        ;;
    *)
        echo "usage: wangka-vohive {status|repair|reenroll}" >&2
        exit 2
        ;;
esac
