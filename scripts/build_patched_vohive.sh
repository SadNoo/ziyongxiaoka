#!/bin/sh
set -eu

SOURCE_REPOSITORY=${1:?usage: build_patched_vohive.sh /path/to/vohive-collection}
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SOURCE_COMMIT=0c3052c524865a92d546f8fea12d873214c5f8e3
PATCH_FILE=${PROJECT_ROOT}/patches/vohive-collection-wangka-work-modes.patch
OUTPUT=${PROJECT_ROOT}/private/build/vohive_v1.5.5-wangka1_linux_arm64
EXPECTED_SHA256=1a624e443e1b96fee4083db91937398a95a9c75f8e32675c5eded036139c614a

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[ -d "${SOURCE_REPOSITORY}/.git" ] || fail "source repository is not a Git checkout"
[ "$(git -C "${SOURCE_REPOSITORY}" rev-parse HEAD)" = "${SOURCE_COMMIT}" ] \
    || fail "vohive-collection commit does not match the audited snapshot"
command -v go >/dev/null 2>&1 || fail "Go is required"
command -v npm >/dev/null 2>&1 || fail "npm is required"
go version | grep -q ' go1\.26\.5 ' || fail "Go 1.26.5 is required for the pinned binary"
node --version | grep -q '^v22\.' || fail "Node.js 22 is required for the pinned frontend"

BUILD_TREE=$(mktemp -d /tmp/wangka-vohive-build.XXXXXX)
cleanup() {
    git -C "${SOURCE_REPOSITORY}" worktree remove --force "${BUILD_TREE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

git -C "${SOURCE_REPOSITORY}" worktree add --detach "${BUILD_TREE}" "${SOURCE_COMMIT}" >/dev/null
git -C "${BUILD_TREE}" apply --check "${PATCH_FILE}"
git -C "${BUILD_TREE}" apply "${PATCH_FILE}"

npm ci --ignore-scripts --prefix "${BUILD_TREE}/vohive/web"
npm run build --prefix "${BUILD_TREE}/vohive/web"
install -d -m 0755 "${BUILD_TREE}/vohive/internal/web/dist"
cp -R "${BUILD_TREE}/vohive/web/dist/." "${BUILD_TREE}/vohive/internal/web/dist/"

install -d -m 0700 "$(dirname "${OUTPUT}")"
(
    cd "${BUILD_TREE}/vohive"
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
        -mod=mod \
        -trimpath \
        -buildvcs=false \
        -tags 'with_utls nomsgpack' \
        -ldflags "-s -w -X 'github.com/iniwex5/vohive/internal/global.Version=v1.5.5-wangka1'" \
        -o "${OUTPUT}" \
        ./cmd/vohive
)
chmod 0755 "${OUTPUT}"
ACTUAL_SHA256=$(shasum -a 256 "${OUTPUT}" | awk '{print $1}')
[ "${ACTUAL_SHA256}" = "${EXPECTED_SHA256}" ] \
    || fail "patched VoHive hash mismatch: ${ACTUAL_SHA256}"

printf 'PATCHED_VOHIVE_BUILD=PASS\n'
printf 'VOHIVE_SHA256=%s\n' "${ACTUAL_SHA256}"
printf 'VOHIVE_BINARY=%s\n' "${OUTPUT}"
