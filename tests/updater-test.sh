#!/bin/sh
# platform: macOS-only -- otool, lipo and PlistBuddy read the built bundles
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
B="${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}"
fail() { echo "FAIL $1"; exit 1; }
n=0
for v in native:rust-updater:x86_64:10.9:dev.mavergreen.rust.rust.updater \
         cross:rust-cross-updater:arm64:11.0:dev.mavergreen.rust.rust-cross.updater; do
  IFS=: read -r var name arch min bid <<EOF
$v
EOF
  app="$B/mavergreen-rust-updater-$var/$name.app"
  [ -d "$app" ] || continue
  n=$((n+1))
  exe="$app/Contents/MacOS/$name"
  lipo -info "$exe" | grep -q "architecture: $arch\$" || fail "$name must be thin $arch"
  otool -l "$exe" | grep -A3 -E 'LC_VERSION_MIN_MACOSX|LC_BUILD_VERSION' | grep -Eq "(version|minos) $min\$" || fail "$name min OS must be $min"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = "$bid" ] || fail "$name bundle id must be $bid (derived: <pkg id>.updater)"
  ! otool -L "$exe" | grep -q 'mavergreen/rust' || fail "$name links the product it updates (self-update circularity)"
done
[ "$n" -gt 0 ] || { echo "no updater built -- skipping"; exit 77; }
echo "OK updater-test ($n)"
