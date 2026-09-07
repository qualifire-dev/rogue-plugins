#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/scripts/shared/env-file.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'ROGUE_TEST_VALUE=trusted\n' > "$work/trusted"
chmod 600 "$work/trusted"
rogue_source_env "$work/trusted"
[ "$ROGUE_TEST_VALUE" = trusted ]
printf 'ROGUE_TEST_VALUE=untrusted\ntouch "%s/executed"\n' "$work" > "$work/unsafe"
for mode in 666 620; do
  chmod "$mode" "$work/unsafe"
  rogue_source_env "$work/unsafe"
  [ "$ROGUE_TEST_VALUE" = trusted ] && [ ! -e "$work/executed" ]
done
ln -s "$work/unsafe" "$work/link"
rogue_source_env "$work/link"
[ "$ROGUE_TEST_VALUE" = trusted ]
if [ "$(id -u)" != 0 ]; then
  if rogue_env_is_trusted "$work/trusted" 1; then
    echo 'FAIL: a user-owned system file was trusted'; exit 1
  fi
fi
rogue_source_env "$work/missing"
echo 'env-file trust: all checks passed'
