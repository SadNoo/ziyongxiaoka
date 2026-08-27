#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
REPOSITORY_ROOT=$(CDPATH= cd -- "$PROJECT_DIR/../../.." && pwd)
OUTPUT_DIR=${1:?请提供桥接组件输出目录}
LIBUSB_ROOT=$("$SCRIPT_DIR/prepare-libusb.sh")
INCLUDE_DIR="$LIBUSB_ROOT/universal/include/libusb-1.0"
LIBRARY_DIR="$LIBUSB_ROOT/universal/lib"
GO_CACHE="$PROJECT_DIR/.build/go-cache"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wisim-bridge.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
mkdir -p "$GO_CACHE"

build_arch() {
  ARCH=$1
  GOARCH=$2
  (
    cd "$PROJECT_DIR"
    CC="clang -arch $ARCH" \
      CGO_ENABLED=1 \
      CGO_CPPFLAGS="-I$INCLUDE_DIR" \
      CGO_LDFLAGS="-L$LIBRARY_DIR -mmacosx-version-min=13.0" \
      GOOS=darwin \
      GOARCH="$GOARCH" \
      GOCACHE="$GO_CACHE" \
      MACOSX_DEPLOYMENT_TARGET=13.0 \
      go build -trimpath -ldflags="-s -w" -o "$WORK_DIR/bridge-$ARCH" .
  )
  OLD_NAME=$(otool -L "$WORK_DIR/bridge-$ARCH" | awk '/libusb/ {print $1; exit}')
  if [ -n "$OLD_NAME" ]; then
    install_name_tool -change "$OLD_NAME" "@loader_path/libusb-1.0.0.dylib" \
      "$WORK_DIR/bridge-$ARCH"
  fi
}

build_arch arm64 arm64
build_arch x86_64 amd64

mkdir -p "$OUTPUT_DIR"
chmod -R u+w "$OUTPUT_DIR"
lipo -create "$WORK_DIR/bridge-arm64" "$WORK_DIR/bridge-x86_64" \
  -output "$OUTPUT_DIR/wisim-modem-bridge"
cp "$LIBRARY_DIR/libusb-1.0.0.dylib" "$OUTPUT_DIR/libusb-1.0.0.dylib"
LEGAL_OUTPUT=$(dirname "$OUTPUT_DIR")/Legal
mkdir -p "$LEGAL_OUTPUT"
cp "$REPOSITORY_ROOT/THIRD_PARTY_NOTICES.md" "$LEGAL_OUTPUT/THIRD_PARTY_NOTICES.md"
cp "$REPOSITORY_ROOT/LICENSES/LGPL-2.1-or-later.txt" \
  "$LEGAL_OUTPUT/LGPL-2.1-or-later.txt"
codesign --force --sign - "$OUTPUT_DIR/libusb-1.0.0.dylib"
codesign --force --sign - --entitlements "$PROJECT_DIR/WiSiMBridge.entitlements" \
  "$OUTPUT_DIR/wisim-modem-bridge"
