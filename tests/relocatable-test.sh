#!/bin/sh
# platform: macOS-only -- otool via build/verify-relocatable.sh
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/build/versions.sh"

audited=0
for pair in "cross:$CROSS_STAGE_ROOT$CROSS_PREFIX" "native:$NATIVE_STAGE_ROOT$NATIVE_PREFIX"; do
  variant="${pair%%:*}"; stage="${pair#*:}"
  [ -x "$stage/bin/rustc" ] || continue
  echo "== relocatable-test: $variant ($stage) =="
  sh "$ROOT/build/verify-relocatable.sh" "$stage"
  ! ls "$stage"/lib/libc++* "$stage"/lib/libunwind* >/dev/null 2>&1 \
    || { echo "FAIL $variant: bundles libc++/libunwind that nothing links (rustc and LLVM use /usr/lib/libc++.1.dylib)"; exit 1; }
  audited=$((audited + 1))
done

[ "$audited" -gt 0 ] || { echo "not built (neither cross nor native staged) -- skipping"; exit 77; }
echo "OK relocatable-test ($audited variant(s))"
