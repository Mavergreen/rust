#!/bin/sh
# SKIP (77) only if NEITHER variant is staged. Audit every staged variant's WHOLE prefix (bin + lib):
# no shipped Mach-O may name an unshippable absolute path (the build scratch dir, clang-22, or a package
# manager like /opt/pkg). The native path is audited too -- run #3 shipped a bin/cargo linking
# /opt/pkg that a single-binary guard missed; this all-of-bin/lib sweep is what catches it.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/build/versions.sh"

audited=0
for pair in "cross:$CROSS_STAGE_ROOT$CROSS_PREFIX" "native:$NATIVE_STAGE_ROOT$NATIVE_PREFIX"; do
  variant="${pair%%:*}"; stage="${pair#*:}"
  [ -x "$stage/bin/rustc" ] || continue
  echo "== relocatable-test: $variant ($stage) =="
  sh "$ROOT/build/verify-relocatable.sh" "$stage"
  audited=$((audited + 1))
done

[ "$audited" -gt 0 ] || { echo "not built (neither cross nor native staged) -- skipping"; exit 77; }
echo "OK relocatable-test ($audited variant(s))"
