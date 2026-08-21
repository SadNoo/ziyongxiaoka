#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
asset_dir="$project_dir/vendor/vohive"
asset_name=vohive_v1.5.5-10-gf9eb85d_linux_arm64
asset_path="$asset_dir/$asset_name"
expected_sha256=4cbfcec06b719609f3d88714b4df63c420e1cf958fbad0b4851a3c495c595661
download_url=https://github.com/overlook940/vohive-release/releases/download/v1.5.5/vohive_v1.5.5_linux_arm64

verify() {
    [ -f "$1" ] || return 1
    actual=$(shasum -a 256 "$1" | awk '{print $1}')
    [ "$actual" = "$expected_sha256" ]
}

if verify "$asset_path"; then
    printf 'VOHIVE_ASSET=%s\n' "$asset_path"
    printf 'VOHIVE_SHA256=%s\n' "$expected_sha256"
    exit 0
fi

if [ -e "$asset_path" ]; then
    echo "existing VoHive asset failed SHA-256 verification: $asset_path" >&2
    exit 1
fi

mkdir -p "$asset_dir"
temporary=$(mktemp "$asset_dir/.vohive-download.XXXXXX")
cleanup() {
    rm -f "$temporary"
}
trap cleanup EXIT INT TERM

curl -L --fail --show-error --proto '=https' --tlsv1.2 \
    -o "$temporary" "$download_url"

if ! verify "$temporary"; then
    echo "downloaded VoHive asset failed SHA-256 verification" >&2
    exit 1
fi

chmod 0755 "$temporary"
mv "$temporary" "$asset_path"
trap - EXIT INT TERM

printf 'VOHIVE_ASSET=%s\n' "$asset_path"
printf 'VOHIVE_SHA256=%s\n' "$expected_sha256"
