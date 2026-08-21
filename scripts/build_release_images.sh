#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BUILDER_ROOT=${PROJECT_ROOT}/tools/OpenStick-Builder
WANGKA_SKIP_ROOTFS=${WANGKA_SKIP_ROOTFS:-0}

case "${WANGKA_SKIP_ROOTFS}" in
    0|1) ;;
    *) printf 'FAIL: WANGKA_SKIP_ROOTFS must be 0 or 1\n' >&2; exit 1 ;;
esac

set -a
. "${PROJECT_ROOT}/config/wangka-defaults.env"
set +a

"${PROJECT_ROOT}/scripts/fetch_vohive_asset.sh"

docker build --platform linux/amd64 \
    -t wangka-openstick-builder:ubuntu22 \
    -f "${BUILDER_ROOT}/Dockerfile.wangka" \
    "${BUILDER_ROOT}"

docker run --rm --privileged --platform linux/amd64 \
    -v "${PROJECT_ROOT}:/project" \
    -w /project/tools/OpenStick-Builder \
    -e CHROOT=/var/tmp/wangka-rootfs \
    -e WANGKA_PROJECT_ROOT=/project \
    -e WANGKA_USER_PASSWORD \
    -e WANGKA_WIFI_PSK \
    -e WANGKA_VOHIVE_USERNAME \
    -e WANGKA_VOHIVE_PASSWORD \
    -e WANGKA_TIMEZONE \
    -e WANGKA_SKIP_ROOTFS \
    wangka-openstick-builder:ubuntu22 \
    sh -ec '
        if [ "$WANGKA_SKIP_ROOTFS" = 1 ]; then
            test -f rootfs.tgz
            mkdir -p "$CHROOT"
            tar xpf rootfs.tgz -C "$CHROOT"
            cp "$(command -v qemu-aarch64-static)" "$CHROOT/usr/bin/"
            WANGKA_PROJECT_ROOT=/project \
                sh /project/scripts/install_release_features.sh "$CHROOT"
            tar cpzf rootfs.tgz \
                --exclude="usr/bin/qemu-aarch64-static" -C "$CHROOT" .
        fi
        SKIP_DEPS=1 SKIP_BOOT=1 SKIP_FW=1 \
            SKIP_ROOTFS="$WANGKA_SKIP_ROOTFS" ./build.sh
    '

docker run --rm --privileged --platform linux/amd64 \
    -v "${PROJECT_ROOT}:/project" \
    -w /project \
    wangka-openstick-builder:ubuntu22 \
    sh scripts/audit_image.sh tools/OpenStick-Builder

mkdir -p "${PROJECT_ROOT}/artifacts/UFI103S-V03/release"
cp "${BUILDER_ROOT}/boot.raw" \
    "${BUILDER_ROOT}/rootfs.raw" \
    "${BUILDER_ROOT}/files/boot.bin" \
    "${BUILDER_ROOT}/files/rootfs.bin" \
    "${PROJECT_ROOT}/artifacts/UFI103S-V03/release/"
(
    cd "${PROJECT_ROOT}/artifacts/UFI103S-V03/release"
    sha256sum boot.raw rootfs.raw boot.bin rootfs.bin > SHA256SUMS
)

printf 'RELEASE_BUILD=PASS\n'
printf 'OUTPUT=%s\n' "${PROJECT_ROOT}/artifacts/UFI103S-V03/release"
