#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
LIBUSB_ROOT=$("$SCRIPT_DIR/prepare-libusb.sh")
GO_CACHE="$PROJECT_DIR/.build/go-test-cache"
mkdir -p "$GO_CACHE"

cd "$PROJECT_DIR"
CGO_CPPFLAGS="-I$LIBUSB_ROOT/universal/include/libusb-1.0" \
  CGO_LDFLAGS="-L$LIBUSB_ROOT/universal/lib -mmacosx-version-min=13.0" \
  DYLD_LIBRARY_PATH="$LIBUSB_ROOT/universal/lib" \
  GOCACHE="$GO_CACHE" \
  MACOSX_DEPLOYMENT_TARGET=13.0 \
  go test ./...
