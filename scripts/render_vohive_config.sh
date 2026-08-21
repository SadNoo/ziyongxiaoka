#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
env_file=${1:-"$project_dir/config/wangka-defaults.env"}
output_file=${2:-/private/tmp/wangka-vohive-config.yaml}
template_file="$project_dir/config/vohive/config.yaml.template"

if [ ! -f "$env_file" ]; then
  echo "missing credential file: $env_file" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$env_file"
set +a

: "${WANGKA_VOHIVE_USERNAME:?missing WANGKA_VOHIVE_USERNAME}"
: "${WANGKA_VOHIVE_PASSWORD:?missing WANGKA_VOHIVE_PASSWORD}"

case "$WANGKA_VOHIVE_USERNAME" in
  *[!A-Za-z0-9._-]*|'')
    echo "VoHive username may contain only letters, digits, dot, underscore and dash" >&2
    exit 1
    ;;
esac

case "$WANGKA_VOHIVE_PASSWORD" in
  *[!A-Za-z0-9._-]*|'')
    echo "VoHive password may contain only letters, digits, dot, underscore and dash" >&2
    exit 1
    ;;
esac

[ "$WANGKA_VOHIVE_USERNAME" = user ] || { echo "VoHive factory username must be user" >&2; exit 1; }
[ "$WANGKA_VOHIVE_PASSWORD" = 123456789 ] || { echo "VoHive factory password mismatch" >&2; exit 1; }

umask 077
sed \
  -e "s/__WANGKA_VOHIVE_USERNAME__/$WANGKA_VOHIVE_USERNAME/g" \
  -e "s/__WANGKA_VOHIVE_PASSWORD__/$WANGKA_VOHIVE_PASSWORD/g" \
  "$template_file" >"$output_file"

chmod 0600 "$output_file"
echo "$output_file"
