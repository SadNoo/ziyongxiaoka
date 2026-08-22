#!/bin/sh
set -eu

ROOTFS=${1:?usage: install_release_features.sh ROOTFS_DIR}
PROJECT_ROOT=${WANGKA_PROJECT_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}
BUILDER_ROOT=${WANGKA_BUILDER_ROOT:-${PROJECT_ROOT}/tools/OpenStick-Builder}
VOHIVE_DIR=${PROJECT_ROOT}/config/vohive
NETWORK_DIR=${PROJECT_ROOT}/config/network
TIME_DIR=${PROJECT_ROOT}/config/time
SSH_DIR=${PROJECT_ROOT}/config/ssh
VOHIVE_BINARY=${WANGKA_VOHIVE_BINARY:-${PROJECT_ROOT}/private/build/vohive_v1.5.5-wangka1_linux_arm64}
VOHIVE_SHA256=1a624e443e1b96fee4083db91937398a95a9c75f8e32675c5eded036139c614a

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[ -d "${ROOTFS}/etc" ] || fail "not a root filesystem: ${ROOTFS}"
[ -f "${VOHIVE_BINARY}" ] || fail "patched VoHive is missing; run scripts/build_patched_vohive.sh first"
[ -n "${WANGKA_USER_PASSWORD:-}" ] || fail "WANGKA_USER_PASSWORD is required"
[ -n "${WANGKA_WIFI_PSK:-}" ] || fail "WANGKA_WIFI_PSK is required"
[ -n "${WANGKA_VOHIVE_USERNAME:-}" ] || fail "WANGKA_VOHIVE_USERNAME is required"
[ -n "${WANGKA_VOHIVE_PASSWORD:-}" ] || fail "WANGKA_VOHIVE_PASSWORD is required"
[ "${WANGKA_TIMEZONE:-}" = Asia/Shanghai ] || fail "factory timezone mismatch"

case "${WANGKA_USER_PASSWORD}${WANGKA_WIFI_PSK}${WANGKA_VOHIVE_USERNAME}${WANGKA_VOHIVE_PASSWORD}" in
    *[!A-Za-z0-9._-]*)
        fail "credentials contain unsupported template characters"
        ;;
esac
[ "${#WANGKA_WIFI_PSK}" -ge 8 ] || fail "WANGKA_WIFI_PSK must contain at least 8 characters"
[ "${WANGKA_USER_PASSWORD}" = 123456789 ] || fail "factory SSH password mismatch"
[ "${WANGKA_WIFI_PSK}" = 123456789 ] || fail "factory Wi-Fi password mismatch"
[ "${WANGKA_VOHIVE_USERNAME}" = user ] || fail "factory VoHive username must be user"
[ "${WANGKA_VOHIVE_PASSWORD}" = 123456789 ] || fail "factory VoHive password mismatch"

printf '%s  %s\n' "${VOHIVE_SHA256}" "${VOHIVE_BINARY}" | sha256sum -c -

# Injection into a previously built rootfs must enforce the same SSH factory
# credential as a clean build.  Update only the password field and preserve
# the original shadow ownership/mode.
grep -q '^user:' "${ROOTFS}/etc/shadow" || fail "user account missing from shadow"
USER_PASSWORD_HASH=$(openssl passwd -6 -salt wangka-factory-v1 "${WANGKA_USER_PASSWORD}")
SHADOW_TMP=$(mktemp "${ROOTFS}/etc/shadow.wangka.XXXXXX")
awk -F: -v OFS=: -v hash="${USER_PASSWORD_HASH}" \
    '$1 == "user" { $2 = hash; found = 1 } { print } END { if (!found) exit 1 }' \
    "${ROOTFS}/etc/shadow" > "${SHADOW_TMP}"
chown --reference="${ROOTFS}/etc/shadow" "${SHADOW_TMP}"
chmod --reference="${ROOTFS}/etc/shadow" "${SHADOW_TMP}"
mv "${SHADOW_TMP}" "${ROOTFS}/etc/shadow"

install -d -m 0700 \
    "${ROOTFS}/etc/vohive" \
    "${ROOTFS}/etc/wangka" \
    "${ROOTFS}/var/lib/vohive/data" \
    "${ROOTFS}/var/lib/vohive/logs" \
    "${ROOTFS}/var/lib/wangka-management"
install -d -m 0755 \
    "${ROOTFS}/etc/NetworkManager/system-connections" \
    "${ROOTFS}/etc/nftables.d" \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants" \
    "${ROOTFS}/usr/lib/wangka" \
    "${ROOTFS}/usr/local/sbin" \
    "${ROOTFS}/usr/share/doc/vohive"
install -d -m 0755 "${ROOTFS}/var/lib/wangka-network"

# Release images must never inherit runtime data from a cached build tree.
# Remove modem/SMS state, APN preferences, logs and SSH trust material before
# writing the fixed factory configuration below.
for clean_dir in \
    "${ROOTFS}/var/lib/vohive/data" \
    "${ROOTFS}/var/lib/vohive/logs" \
    "${ROOTFS}/var/lib/wangka-network"; do
    find "${clean_dir}" -mindepth 1 -depth -delete
done
for ssh_home in "${ROOTFS}/root/.ssh" "${ROOTFS}/home/user/.ssh"; do
    if [ -d "${ssh_home}" ]; then
        find "${ssh_home}" -mindepth 1 -depth -delete
    fi
done
rm -f "${ROOTFS}/var/lib/dbus/machine-id"
: > "${ROOTFS}/etc/machine-id"

install -m 0755 "${VOHIVE_BINARY}" "${ROOTFS}/usr/local/sbin/vohive"
install -m 0755 "${VOHIVE_BINARY}" "${ROOTFS}/usr/lib/wangka/vohive"
install -m 0755 "${VOHIVE_DIR}/wangka-vohive-enroll.py" \
    "${ROOTFS}/usr/local/sbin/wangka-vohive-enroll"
install -m 0755 "${VOHIVE_DIR}/wangka-vohive-qmi-owner.py" \
    "${ROOTFS}/usr/local/sbin/wangka-vohive-qmi-owner"
install -m 0755 "${VOHIVE_DIR}/wangka-management-proxy.py" \
    "${ROOTFS}/usr/local/sbin/wangka-management-proxy"
install -m 0755 "${VOHIVE_DIR}/wangka-vohive-maintenance.sh" \
    "${ROOTFS}/usr/local/sbin/wangka-vohive"
install -m 0755 "${NETWORK_DIR}/wangka-network-ready.sh" \
    "${ROOTFS}/usr/local/sbin/wangka-network-ready"
install -m 0755 "${NETWORK_DIR}/wangka-uplink-manager.py" \
    "${ROOTFS}/usr/local/sbin/wangka-uplink"
install -m 0755 "${NETWORK_DIR}/wangka-work-mode.py" \
    "${ROOTFS}/usr/local/sbin/wangka-work-mode"
install -m 0755 "${TIME_DIR}/wangka-timekeeper.sh" \
    "${ROOTFS}/usr/local/sbin/wangka-timekeeper"
rm -f "${ROOTFS}/etc/NetworkManager/dispatcher.d/90-wangka-management-alias"
install -m 0644 "${VOHIVE_DIR}/wangka-web.nft" \
    "${ROOTFS}/etc/nftables.d/wangka-web.nft"
install -m 0644 "${NETWORK_DIR}/wangka-host-uplink.nft" \
    "${ROOTFS}/etc/nftables.d/wangka-host-uplink.nft"
install -m 0644 "${PROJECT_ROOT}/vendor/vohive/LICENSE" \
    "${ROOTFS}/usr/share/doc/vohive/LICENSE"

for unit in \
    vohive.service \
    wangka-vohive-enroll.service \
    wangka-web-firewall.service \
    wangka-web-proxy.service \
    wangka-web-proxy.socket; do
    install -m 0644 "${VOHIVE_DIR}/${unit}" \
        "${ROOTFS}/etc/systemd/system/${unit}"
done
install -m 0644 "${NETWORK_DIR}/wangka-network-ready.service" \
    "${ROOTFS}/etc/systemd/system/wangka-network-ready.service"
for unit in wangka-uplink-reconcile.service wangka-uplink-reconcile.timer; do
    install -m 0644 "${NETWORK_DIR}/${unit}" "${ROOTFS}/etc/systemd/system/${unit}"
done
for unit in wangka-timekeeper.service wangka-timekeeper-save.service wangka-timekeeper.timer; do
    install -m 0644 "${TIME_DIR}/${unit}" "${ROOTFS}/etc/systemd/system/${unit}"
done
install -m 0644 "${SSH_DIR}/wangka-ssh-host-keys.service" \
    "${ROOTFS}/etc/systemd/system/wangka-ssh-host-keys.service"
date -u +%s > "${ROOTFS}/usr/lib/wangka/build-epoch"
chmod 0644 "${ROOTFS}/usr/lib/wangka/build-epoch"

sed \
    -e "s/__WANGKA_VOHIVE_USERNAME__/${WANGKA_VOHIVE_USERNAME}/g" \
    -e "s/__WANGKA_VOHIVE_PASSWORD__/${WANGKA_VOHIVE_PASSWORD}/g" \
    "${VOHIVE_DIR}/config.yaml.template" \
    > "${ROOTFS}/etc/vohive/config.yaml"
chmod 0600 "${ROOTFS}/etc/vohive/config.yaml"
install -m 0600 "${ROOTFS}/etc/vohive/config.yaml" \
    "${ROOTFS}/usr/lib/wangka/vohive-default.yaml"
printf '%s\n' '{"access_mode":"login-required","generation":0,"initialized":false,"uplink_mode":"device-uplink","work_mode":"dual"}' \
    > "${ROOTFS}/var/lib/wangka-management/state.json"
chmod 0600 "${ROOTFS}/var/lib/wangka-management/state.json"
printf '{"password":"%s","username":"%s"}\n' \
    "${WANGKA_VOHIVE_PASSWORD}" "${WANGKA_VOHIVE_USERNAME}" \
    > "${ROOTFS}/var/lib/wangka-management/vohive-local-auth.json"
chmod 0600 "${ROOTFS}/var/lib/wangka-management/vohive-local-auth.json"

# The builder runs inside Docker; never ship its private resolver address in
# the device image. device-uplink starts with domestic fallback resolvers and
# later prefers DNS supplied by an active LTE profile. host-uplink replaces
# these with the Mac's current resolvers and restores them on rollback.
install -m 0644 "${NETWORK_DIR}/resolv.conf.device-uplink" \
    "${ROOTFS}/var/lib/wangka-network/resolv.conf"
ln -sfn /var/lib/wangka-network/resolv.conf "${ROOTFS}/etc/resolv.conf"

install -m 0600 "${BUILDER_ROOT}/configs/hotspot.nmconnection" \
    "${ROOTFS}/etc/NetworkManager/system-connections/hotspot.nmconnection"
sed -i "s/__WANGKA_WIFI_PSK__/${WANGKA_WIFI_PSK}/" \
    "${ROOTFS}/etc/NetworkManager/system-connections/hotspot.nmconnection"
USB_PROFILE="${ROOTFS}/etc/NetworkManager/system-connections/usb.nmconnection"
if ! grep -q '^never-default=true$' "${USB_PROFILE}"; then
    sed -i '/^method=shared$/a never-default=true' "${USB_PROFILE}"
fi
ln -sfn "/usr/share/zoneinfo/${WANGKA_TIMEZONE}" "${ROOTFS}/etc/localtime"
printf '%s\n' "${WANGKA_TIMEZONE}" > "${ROOTFS}/etc/timezone"
install -m 0755 "${BUILDER_ROOT}/scripts/msm-firmware-loader.sh" \
    "${ROOTFS}/usr/sbin/msm-firmware-loader.sh"
install -m 0755 "${NETWORK_DIR}/wangka-modem.py" \
    "${ROOTFS}/usr/local/sbin/wangka-modem"
install -d -m 0755 "${ROOTFS}/usr/local/bin"
ln -sf ../sbin/wangka-modem "${ROOTFS}/usr/local/bin/wangka-modem"

# One QMI owner is mandatory on this onboard modem.  VoHive provides LTE and
# SMS together; mask ModemManager so its recovery loop cannot compete.
ln -sfn /dev/null "${ROOTFS}/etc/systemd/system/ModemManager.service"
rm -f "${ROOTFS}/etc/systemd/system/multi-user.target.wants/ModemManager.service"
rm -f "${ROOTFS}/etc/systemd/system/dbus-org.freedesktop.ModemManager1.service"
LTE_PROFILE="${ROOTFS}/etc/NetworkManager/system-connections/lte.nmconnection"
rm -f "${LTE_PROFILE}"

# NetworkManager owns its private dnsmasq instance for the two shared LANs.
# Do not let the distro service compete for port 53, and do not delay boot for
# an LTE uplink that may not exist before a SIM is inserted.
ln -sf /dev/null "${ROOTFS}/etc/systemd/system/dnsmasq.service"
ln -sf /dev/null "${ROOTFS}/etc/systemd/system/NetworkManager-wait-online.service"
rm -f "${ROOTFS}/etc/systemd/system/multi-user.target.wants/dnsmasq.service"
rm -f "${ROOTFS}/etc/systemd/system/network-online.target.wants/NetworkManager-wait-online.service"

ln -sf ../vohive.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/vohive.service"
ln -sf ../wangka-vohive-enroll.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/wangka-vohive-enroll.service"
ln -sf ../wangka-web-firewall.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/wangka-web-firewall.service"
ln -sf ../wangka-web-proxy.socket \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/wangka-web-proxy.socket"
ln -sf ../wangka-network-ready.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/wangka-network-ready.service"
ln -sf ../wangka-ssh-host-keys.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/wangka-ssh-host-keys.service"
install -d -m 0755 \
    "${ROOTFS}/etc/systemd/system/sysinit.target.wants" \
    "${ROOTFS}/etc/systemd/system/timers.target.wants"
ln -sf ../wangka-timekeeper.service \
    "${ROOTFS}/etc/systemd/system/sysinit.target.wants/wangka-timekeeper.service"
ln -sf ../wangka-timekeeper.timer \
    "${ROOTFS}/etc/systemd/system/timers.target.wants/wangka-timekeeper.timer"
ln -sf ../wangka-uplink-reconcile.timer \
    "${ROOTFS}/etc/systemd/system/timers.target.wants/wangka-uplink-reconcile.timer"
rm -f "${ROOTFS}/etc/systemd/system/sockets.target.wants/wangka-web-proxy.socket"

# Host keys identify a physical SSH server.  Never clone the builder's keys
# into every flashed device; remove all generated keys from the image and let
# the first boot service create a unique set before ssh.service starts.
for key_type in rsa ecdsa ed25519; do
    rm -f \
        "${ROOTFS}/etc/ssh/ssh_host_${key_type}_key" \
        "${ROOTFS}/etc/ssh/ssh_host_${key_type}_key.pub"
done

printf 'FEATURE_INSTALL=PASS\n'
printf 'FACTORY_SSH_PASSWORD=SET_AND_REDACTED\n'
printf 'VOHIVE_SHA256=%s\n' "${VOHIVE_SHA256}"
printf 'USB_MANAGEMENT=http://192.168.5.1/\n'
printf 'WIFI_MANAGEMENT=http://192.168.4.1/\n'
printf 'MACOS_HOST_UPLINK=INSTALLED_UNPAIRED\n'
