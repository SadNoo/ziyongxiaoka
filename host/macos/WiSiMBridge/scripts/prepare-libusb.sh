#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
CACHE_ROOT=${1:-"$PROJECT_DIR/.build/libusb-1.0.30"}
VERSION=1.0.30
ARCHIVE_NAME="libusb-$VERSION.tar.bz2"
SOURCE_URL="https://github.com/libusb/libusb/releases/download/v$VERSION/$ARCHIVE_NAME"
EXPECTED_SHA256=fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
READY_MARKER="$CACHE_ROOT/.ready"

if [ -f "$READY_MARKER" ] && \
  [ -f "$CACHE_ROOT/universal/lib/libusb-1.0.0.dylib" ] && \
  [ -e "$CACHE_ROOT/universal/lib/libusb-1.0.dylib" ]; then
  printf '%s\n' "$CACHE_ROOT"
  exit 0
fi

mkdir -p "$(dirname "$CACHE_ROOT")"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wisim-libusb.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

ARCHIVE="$WORK_DIR/$ARCHIVE_NAME"
curl -L --fail --silent --show-error --retry 3 -o "$ARCHIVE" "$SOURCE_URL"
ACTUAL_SHA256=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  echo "libusb 源码校验失败：$ACTUAL_SHA256" >&2
  exit 1
fi

tar -xjf "$ARCHIVE" -C "$WORK_DIR"
SOURCE_DIR="$WORK_DIR/libusb-$VERSION"

build_arch() {
  ARCH=$1
  BUILD_DIR="$WORK_DIR/build-$ARCH"
  INSTALL_DIR="$WORK_DIR/install-$ARCH"
  mkdir -p "$BUILD_DIR" "$INSTALL_DIR"
  (
    cd "$BUILD_DIR"
    lt_cv_sys_max_cmd_len=262144 \
      MACOSX_DEPLOYMENT_TARGET=13.0 \
      CC="clang -arch $ARCH" \
      CFLAGS="-O2 -mmacosx-version-min=13.0" \
      LDFLAGS="-mmacosx-version-min=13.0" \
      "$SOURCE_DIR/configure" \
        --prefix="$INSTALL_DIR" \
        --disable-static \
        --enable-shared
    make -j4
    make install
  ) >&2
}

build_arch arm64
build_arch x86_64

ASSEMBLY_DIR="$WORK_DIR/universal"
mkdir -p "$ASSEMBLY_DIR/lib" "$ASSEMBLY_DIR/include/libusb-1.0"
lipo -create \
  "$WORK_DIR/install-arm64/lib/libusb-1.0.0.dylib" \
  "$WORK_DIR/install-x86_64/lib/libusb-1.0.0.dylib" \
  -output "$ASSEMBLY_DIR/lib/libusb-1.0.0.dylib"
install_name_tool -id "@rpath/libusb-1.0.0.dylib" "$ASSEMBLY_DIR/lib/libusb-1.0.0.dylib"
ln -s "libusb-1.0.0.dylib" "$ASSEMBLY_DIR/lib/libusb-1.0.dylib"
cp "$WORK_DIR/install-arm64/include/libusb-1.0/libusb.h" \
  "$ASSEMBLY_DIR/include/libusb-1.0/libusb.h"

if [ -e "$CACHE_ROOT" ]; then
  mv "$CACHE_ROOT" "$CACHE_ROOT.incomplete.$(date +%Y%m%d%H%M%S)"
fi
mkdir -p "$CACHE_ROOT"
mv "$ASSEMBLY_DIR" "$CACHE_ROOT/universal"
printf '%s\n' "$EXPECTED_SHA256" > "$READY_MARKER"
printf '%s\n' "$CACHE_ROOT"
