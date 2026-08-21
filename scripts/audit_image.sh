#!/bin/sh
set -eu

IMAGE_DIR=${1:-/work}
BOOT_MOUNT=$(mktemp -d)
ROOT_MOUNT=$(mktemp -d)

cleanup() {
    mountpoint -q "${ROOT_MOUNT}" && umount "${ROOT_MOUNT}" || true
    mountpoint -q "${BOOT_MOUNT}" && umount "${BOOT_MOUNT}" || true
    rmdir "${ROOT_MOUNT}" "${BOOT_MOUNT}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

require_file() {
    [ -f "$1" ] || fail "missing file: $1"
}

require_link() {
    [ -L "$1" ] || fail "missing service link: $1"
}

require_masked() {
    [ -L "$1" ] || fail "service is not masked: $1"
    [ "$(readlink "$1")" = '/dev/null' ] || fail "service mask does not point to /dev/null: $1"
}

mount -o loop,ro "${IMAGE_DIR}/boot.raw" "${BOOT_MOUNT}"
mount -o loop,ro "${IMAGE_DIR}/rootfs.raw" "${ROOT_MOUNT}"

require_file "${BOOT_MOUNT}/vmlinuz"
require_file "${BOOT_MOUNT}/extlinux/extlinux.conf"
require_file "${BOOT_MOUNT}/dtbs/qcom/msm8916-thwc-ufi001c.dtb"
grep -q 'fdt /dtbs/qcom/msm8916-thwc-ufi001c.dtb' \
    "${BOOT_MOUNT}/extlinux/extlinux.conf" || fail "wrong extlinux DTB"
grep -aq 'thwc,ufi001c' \
    "${BOOT_MOUNT}/dtbs/qcom/msm8916-thwc-ufi001c.dtb" || fail "DTB compatible string missing"

for package in \
    libqmi-utils modemmanager network-manager nftables openssh-server \
    python3 python3-dbus python3-gi qrtr-tools rmtfs sqlite3; do
    dpkg-query --admindir="${ROOT_MOUNT}/var/lib/dpkg" \
        -W -f='${db:Status-Abbrev}' "${package}" 2>/dev/null \
        | grep -q '^ii ' || fail "package not installed: ${package}"
done

require_file "${ROOT_MOUNT}/usr/bin/gt"
require_file "${ROOT_MOUNT}/usr/lib/libusbgx.so.2.0.0"
require_file "${ROOT_MOUNT}/etc/gt/templates/cdc-ecm.scheme"
require_file "${ROOT_MOUNT}/etc/systemd/system/usb-gadget.service"
grep -q 'gt load cdc-ecm.scheme cdc-ecm' \
    "${ROOT_MOUNT}/etc/systemd/system/usb-gadget.service" || fail "ECM gadget service is not configured"
require_link "${ROOT_MOUNT}/etc/systemd/system/multi-user.target.wants/usb-gadget.service"
require_link "${ROOT_MOUNT}/etc/systemd/system/multi-user.target.wants/msm-firmware-loader.service"
require_link "${ROOT_MOUNT}/etc/systemd/system/multi-user.target.wants/resize-rootfs.service"
require_link "${ROOT_MOUNT}/etc/systemd/system/multi-user.target.wants/ModemManager.service"
require_link "${ROOT_MOUNT}/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
require_link "${ROOT_MOUNT}/etc/systemd/system/multi-user.target.wants/wangka-network-ready.service"
require_link "${ROOT_MOUNT}/etc/systemd/system/sysinit.target.wants/wangka-timekeeper.service"
require_link "${ROOT_MOUNT}/etc/systemd/system/timers.target.wants/wangka-timekeeper.timer"
require_link "${ROOT_MOUNT}/etc/systemd/system/multi-user.target.wants/vohive.service"
require_link "${ROOT_MOUNT}/etc/systemd/system/multi-user.target.wants/wangka-vohive-enroll.service"
require_link "${ROOT_MOUNT}/etc/systemd/system/multi-user.target.wants/wangka-web-firewall.service"
require_link "${ROOT_MOUNT}/etc/systemd/system/multi-user.target.wants/wangka-web-proxy.socket"
[ ! -e "${ROOT_MOUNT}/etc/systemd/system/sockets.target.wants/wangka-web-proxy.socket" ] \
    || fail "obsolete sockets.target proxy link remains"
require_masked "${ROOT_MOUNT}/etc/systemd/system/dnsmasq.service"
require_masked "${ROOT_MOUNT}/etc/systemd/system/NetworkManager-wait-online.service"
require_file "${ROOT_MOUNT}/usr/local/sbin/wangka-modem"
require_file "${ROOT_MOUNT}/usr/local/sbin/wangka-network-ready"
require_file "${ROOT_MOUNT}/etc/systemd/system/wangka-network-ready.service"
require_file "${ROOT_MOUNT}/usr/local/sbin/wangka-timekeeper"
require_file "${ROOT_MOUNT}/etc/systemd/system/wangka-timekeeper.service"
require_file "${ROOT_MOUNT}/etc/systemd/system/wangka-timekeeper-save.service"
require_file "${ROOT_MOUNT}/etc/systemd/system/wangka-timekeeper.timer"
require_file "${ROOT_MOUNT}/usr/lib/wangka/build-epoch"
BUILD_EPOCH=$(sed -n '1p' "${ROOT_MOUNT}/usr/lib/wangka/build-epoch")
case "${BUILD_EPOCH}" in ''|*[!0-9]*) fail "invalid build epoch" ;; esac
[ "${BUILD_EPOCH}" -ge 1735689600 ] && [ "${BUILD_EPOCH}" -le 4102444800 ] \
    || fail "build epoch outside allowed range"
[ "$(cat "${ROOT_MOUNT}/etc/timezone")" = Asia/Shanghai ] \
    || fail "factory timezone mismatch"
grep -q 'last-trusted-epoch' "${ROOT_MOUNT}/usr/local/sbin/wangka-timekeeper" \
    || fail "persistent clock state missing"
grep -q '^Requires=NetworkManager.service usb-gadget.service$' \
    "${ROOT_MOUNT}/etc/systemd/system/wangka-network-ready.service" \
    || fail "management network readiness dependencies missing"
grep -q 'connection up usb' "${ROOT_MOUNT}/usr/local/sbin/wangka-network-ready" \
    || fail "USB management network recovery missing"
grep -q 'connection up hotspot' "${ROOT_MOUNT}/usr/local/sbin/wangka-network-ready" \
    || fail "Wi-Fi management network recovery missing"
grep -q 'sms-send NUMBER TEXT' "${ROOT_MOUNT}/usr/local/sbin/wangka-modem" || fail "SMS management command missing"
require_link "${ROOT_MOUNT}/usr/local/bin/wangka-modem"

USB_PROFILE="${ROOT_MOUNT}/etc/NetworkManager/system-connections/usb.nmconnection"
require_file "${USB_PROFILE}"
grep -q '^interface-name=usb0$' "${USB_PROFILE}" || fail "USB network profile is not bound to usb0"
grep -q '^address1=192.168.5.1/24$' "${USB_PROFILE}" || fail "USB network address mismatch"
grep -q '^method=shared$' "${USB_PROFILE}" || fail "USB network sharing is disabled"

HOTSPOT="${ROOT_MOUNT}/etc/NetworkManager/system-connections/hotspot.nmconnection"
require_file "${HOTSPOT}"
[ "$(stat -c '%a' "${HOTSPOT}")" = '600' ] || fail "hotspot profile permissions are not 0600"
grep -q '^ssid=Wangka-UFI103S$' "${HOTSPOT}" || fail "wrong hotspot SSID"
grep -q '^channel=6$' "${HOTSPOT}" || fail "hotspot channel is not fixed to 6"
grep -q '^cloned-mac-address=permanent$' "${HOTSPOT}" || fail "hotspot does not use its permanent MAC"
grep -q '^key-mgmt=wpa-psk$' "${HOTSPOT}" || fail "hotspot is not WPA-PSK"
grep -q '^pairwise=ccmp;$' "${HOTSPOT}" || fail "hotspot pairwise cipher is not CCMP"
grep -q '^pmf=1$' "${HOTSPOT}" || fail "hotspot PMF compatibility setting missing"
grep -q '^proto=rsn;$' "${HOTSPOT}" || fail "hotspot is not WPA2/RSN-only"
grep -q '^psk=' "${HOTSPOT}" || fail "hotspot PSK missing"
grep -q '__WANGKA_WIFI_PSK__' "${HOTSPOT}" && fail "hotspot PSK placeholder remains"
grep -q '^psk=123456789$' "${HOTSPOT}" || fail "factory Wi-Fi password mismatch"
grep -q '^shared-dhcp-range=192.168.4.20,192.168.4.250$' "${HOTSPOT}" \
    || fail "hotspot DHCP range mismatch"

VOHIVE_BIN="${ROOT_MOUNT}/usr/local/sbin/vohive"
require_file "${VOHIVE_BIN}"
[ "$(sha256sum "${VOHIVE_BIN}" | cut -d' ' -f1)" = \
    '4cbfcec06b719609f3d88714b4df63c420e1cf958fbad0b4851a3c495c595661' ] \
    || fail "VoHive ARM64 binary hash mismatch"
require_file "${ROOT_MOUNT}/etc/vohive/config.yaml"
[ "$(stat -c '%a' "${ROOT_MOUNT}/etc/vohive/config.yaml")" = '600' ] \
    || fail "VoHive config permissions are not 0600"
grep -q '^  port: 17575$' "${ROOT_MOUNT}/etc/vohive/config.yaml" \
    || fail "VoHive port mismatch"
grep -q '__WANGKA_VOHIVE_' "${ROOT_MOUNT}/etc/vohive/config.yaml" \
    && fail "VoHive credential placeholder remains"
grep -q '^  username: "user"$' "${ROOT_MOUNT}/etc/vohive/config.yaml" \
    || fail "factory VoHive username mismatch"
grep -q '^  password: "123456789"$' "${ROOT_MOUNT}/etc/vohive/config.yaml" \
    || fail "factory VoHive password mismatch"
require_file "${ROOT_MOUNT}/usr/local/sbin/wangka-vohive-enroll"
require_file "${ROOT_MOUNT}/usr/local/sbin/wangka-management-proxy"
require_file "${ROOT_MOUNT}/usr/local/sbin/wangka-vohive"
require_file "${ROOT_MOUNT}/usr/lib/wangka/vohive"
[ "$(sha256sum "${ROOT_MOUNT}/usr/lib/wangka/vohive" | cut -d' ' -f1)" = \
    '4cbfcec06b719609f3d88714b4df63c420e1cf958fbad0b4851a3c495c595661' ] \
    || fail "canonical VoHive repair asset hash mismatch"
require_file "${ROOT_MOUNT}/usr/lib/wangka/vohive-default.yaml"
require_file "${ROOT_MOUNT}/var/lib/wangka-management/state.json"
[ "$(stat -c '%a' "${ROOT_MOUNT}/var/lib/wangka-management/state.json")" = '600' ] \
    || fail "management state permissions are not 0600"
grep -q '"initialized": false' "${ROOT_MOUNT}/var/lib/wangka-management/state.json" \
    || fail "factory onboarding is not required"
grep -q 'path == "/api/system/uninstall"' "${ROOT_MOUNT}/usr/local/sbin/wangka-management-proxy" \
    || fail "VoHive uninstall route is not blocked"
grep -q '网页卸载已永久禁用' "${ROOT_MOUNT}/usr/local/sbin/wangka-management-proxy" \
    || fail "VoHive uninstall rejection response missing"
grep -q 'SYSTEM_DEVICE_HTML' "${ROOT_MOUNT}/usr/local/sbin/wangka-management-proxy" \
    || fail "system device page missing"
grep -q 'path == "/wangka/api/time"' "${ROOT_MOUNT}/usr/local/sbin/wangka-management-proxy" \
    || fail "browser time synchronization endpoint missing"
[ ! -e "${ROOT_MOUNT}/etc/NetworkManager/dispatcher.d/90-wangka-management-alias" ] \
    || fail "obsolete Wi-Fi management alias remains"
require_file "${ROOT_MOUNT}/etc/nftables.d/wangka-web.nft"
grep -q 'iifname "wlan0" ip saddr 192.168.4.0/24' \
    "${ROOT_MOUNT}/etc/nftables.d/wangka-web.nft" \
    || fail "VoHive Wi-Fi firewall rule missing"
require_file "${ROOT_MOUNT}/usr/share/doc/vohive/LICENSE"
grep -q '^ListenStream=192.168.4.1:80$' \
    "${ROOT_MOUNT}/etc/systemd/system/wangka-web-proxy.socket" \
    || fail "VoHive Wi-Fi port 80 listener mismatch"
grep -q '^ListenStream=192.168.5.1:80$' \
    "${ROOT_MOUNT}/etc/systemd/system/wangka-web-proxy.socket" \
    || fail "VoHive USB port 80 listener mismatch"
grep -q '^ListenStream=192.168.4.1:7575$' \
    "${ROOT_MOUNT}/etc/systemd/system/wangka-web-proxy.socket" \
    || fail "VoHive Wi-Fi protected 7575 listener mismatch"
grep -q '^ListenStream=192.168.5.1:7575$' \
    "${ROOT_MOUNT}/etc/systemd/system/wangka-web-proxy.socket" \
    || fail "VoHive USB protected 7575 listener mismatch"
grep -q '^ExecStart=/usr/local/sbin/wangka-management-proxy --socket-activation$' \
    "${ROOT_MOUNT}/etc/systemd/system/wangka-web-proxy.service" \
    || fail "protected management proxy service mismatch"
grep -q 'tcp dport 17575 drop' "${ROOT_MOUNT}/etc/nftables.d/wangka-web.nft" \
    || fail "raw VoHive backend is not blocked"

ROOT_HASH=$(awk -F: '$1 == "root" { print $2 }' "${ROOT_MOUNT}/etc/shadow")
case "${ROOT_HASH}" in
    '!'*|'*'*) ;;
    *) fail "root account is not locked" ;;
esac
USER_HASH=$(awk -F: '$1 == "user" { print $2 }' "${ROOT_MOUNT}/etc/shadow")
[ -n "${USER_HASH}" ] || fail "user password hash missing"
case "${USER_HASH}" in
    '!'*|'*'*) fail "user account is locked" ;;
esac
perl -e 'exit(crypt("123456789", $ARGV[0]) eq $ARGV[0] ? 0 : 1)' "${USER_HASH}" \
    || fail "factory SSH password mismatch"
grep -q '^user:.*:/home/user:/bin/bash$' "${ROOT_MOUNT}/etc/passwd" || fail "user account missing"
grep -q '^PermitRootLogin no$' "${ROOT_MOUNT}/etc/ssh/sshd_config.d/wangka.conf" || fail "SSH root login is not disabled"
grep -q '^PasswordAuthentication yes$' "${ROOT_MOUNT}/etc/ssh/sshd_config.d/wangka.conf" || fail "SSH user login is not enabled"

ROOT_USED=$(df -B1 --output=used "${ROOT_MOUNT}" | tail -n 1 | tr -d ' ')
ROOT_FREE=$(df -B1 --output=avail "${ROOT_MOUNT}" | tail -n 1 | tr -d ' ')
BOOT_USED=$(df -B1 --output=used "${BOOT_MOUNT}" | tail -n 1 | tr -d ' ')

printf 'IMAGE_AUDIT=PASS\n'
printf 'KERNEL=%s\n' "$(file -b "${BOOT_MOUNT}/vmlinuz")"
printf 'DTB=msm8916-thwc-ufi001c.dtb\n'
printf 'USB_GADGET=CDC_ECM\n'
printf 'MANAGEMENT_NETWORK_RETRY=YES\n'
printf 'PERSISTENT_TIMEKEEPER=YES\n'
printf 'FACTORY_TIMEZONE=Asia/Shanghai\n'
printf 'USB_ADDRESS=192.168.5.1/24\n'
printf 'HOTSPOT_SSID=Wangka-UFI103S\n'
printf 'HOTSPOT_PSK=SET_AND_REDACTED\n'
printf 'ROOT_ACCOUNT=LOCKED\n'
printf 'LOGIN_ACCOUNT=user\n'
printf 'FACTORY_PASSWORD_POLICY=123456789\n'
printf 'ONBOARDING_REQUIRED=YES\n'
printf 'VOHIVE_UNINSTALL_BLOCKED=YES\n'
printf 'MODEM_CLI=wangka-modem\n'
printf 'VOHIVE_SHA256=4cbfcec06b719609f3d88714b4df63c420e1cf958fbad0b4851a3c495c595661\n'
printf 'VOHIVE_USB_URL=http://192.168.5.1/\n'
printf 'VOHIVE_WIFI_URL=http://192.168.4.1/\n'
printf 'ROOTFS_USED_BYTES=%s\n' "${ROOT_USED}"
printf 'ROOTFS_FREE_BYTES=%s\n' "${ROOT_FREE}"
printf 'BOOT_USED_BYTES=%s\n' "${BOOT_USED}"
