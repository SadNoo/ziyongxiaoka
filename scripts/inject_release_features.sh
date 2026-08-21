#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
IMAGE_DIR=${1:-${PROJECT_ROOT}/tools/OpenStick-Builder}
ROOTFS_IMAGE=${IMAGE_DIR}/rootfs.raw

[ -f "${ROOTFS_IMAGE}" ] || {
    printf 'FAIL: missing %s\n' "${ROOTFS_IMAGE}" >&2
    exit 1
}

set -a
. "${PROJECT_ROOT}/config/wangka-defaults.env"
set +a

docker run --rm --privileged --platform linux/amd64 \
    -v "${PROJECT_ROOT}:/project" \
    -w /project \
    -e WANGKA_USER_PASSWORD \
    -e WANGKA_WIFI_PSK \
    -e WANGKA_VOHIVE_USERNAME \
    -e WANGKA_VOHIVE_PASSWORD \
    -e WANGKA_TIMEZONE \
    wangka-openstick-builder:ubuntu22 \
    sh -ec '
        image=/project/tools/OpenStick-Builder/rootfs.raw
        mount_dir=$(mktemp -d)
        cleanup() {
            mountpoint -q "$mount_dir" && umount "$mount_dir" || true
            rmdir "$mount_dir" 2>/dev/null || true
        }
        trap cleanup EXIT INT TERM
        mount -o loop "$image" "$mount_dir"
        WANGKA_PROJECT_ROOT=/project \
            sh /project/scripts/install_release_features.sh "$mount_dir"
        sync
    '

docker run --rm --privileged --platform linux/amd64 \
    -v "${PROJECT_ROOT}:/project" \
    -w /project/tools/OpenStick-Builder \
    wangka-openstick-builder:ubuntu22 \
    sh -ec 'img2simg rootfs.raw files/rootfs.bin'

printf 'IMAGE_INJECTION=PASS\n'
