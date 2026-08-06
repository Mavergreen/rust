#!/bin/sh
# SKIP (77) until the cross toolchain is staged. Then assert no shipped Mach-O names an unshippable
# absolute path (the build scratch dir or the clang-22 prefix must be gone from load commands).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/build/versions.sh"
STAGE="$WORK/stage$CROSS_PREFIX"
[ -x "$STAGE/bin/rustc" ] || { echo "not built -- skipping"; exit 77; }
sh "$ROOT/build/verify-relocatable.sh" "$STAGE"
echo "OK relocatable-test"
