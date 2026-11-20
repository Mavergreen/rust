#!/bin/sh
# platform: host-agnostic
#   usage: tests/updater-test.sh
#          Checks every updater build/build-updater.sh left under MAVERICKS_BUILD_ROOT. With none there,
#          it builds the native one into a scratch build root and checks that.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
B="${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}"
fail() { echo "FAIL $1"; exit 1; }
t="$(mktemp -d "${TMPDIR:-/tmp}/updater-test.XXXXXX")"; trap 'rm -rf "$t"' EXIT
REPO_ROOT="$ROOT"; export REPO_ROOT
. "$ROOT/build/versions.sh"
. "$ROOT/tests/lib/clang22.sh"
. "$ROOT/build/lib-rust.sh"; macho_tools
STEVEDORE="$(sh "$SHIPYARD_SCRIPTS/fetch_stevedore.sh")" || fail "no stevedore"
SPARKLE="$(sh "$SHIPYARD_SCRIPTS/fetch_sparkle_framework.sh")" || fail "no pinned Sparkle"
check() {
  var="$1"; name="$2"; arch="$3"; min="$4"; bid="$5"; app="$6"
  exe="$app/Contents/MacOS/$name"
  "$LIPO" -info "$exe" | grep -Eq "architecture: $arch *\$" || fail "$name must be thin $arch"
  # platform: llvm-otool prints LC_BUILD_VERSION's sdk before its minos, so minos is the fourth line
  #           after cmd (Apple's otool prints it third)
  "$OTOOL" -l "$exe" | grep -A4 -E 'LC_VERSION_MIN_MACOSX|LC_BUILD_VERSION' > "$t/lc"
  grep -Eq "(version|minos) $min\$" "$t/lc" || fail "$name min OS must be $min"
  [ "$var" != native ] || grep -Eq "sdk $min\$" "$t/lc" || fail "$name must be built against the $min SDK"
  [ "$("$STEVEDORE" plist get "$app/Contents/Info.plist" CFBundleIdentifier)" = "$bid" ] \
    || fail "$name bundle id must be $bid (derived: <pkg id>.updater)"
  ! "$OTOOL" -L "$exe" | grep -q 'mavergreen/rust' || fail "$name links the product it updates (self-update circularity)"
  sh "$SHIPYARD_SCRIPTS/assert_sparkle_pristine.sh" "$app/Contents/Frameworks/Sparkle.framework" "$SPARKLE" \
    || fail "$name embeds a Sparkle.framework that is not the pinned one"
}
n=0
for v in native:rust-updater:x86_64:10.9:dev.mavergreen.rust.rust.updater \
         cross:rust-cross-updater:arm64:11.0:dev.mavergreen.rust.rust-cross.updater; do
  IFS=: read -r var name arch min bid <<EOF
$v
EOF
  app="$B/mavergreen-rust-updater-$var/$name.app"
  [ -d "$app" ] || continue
  n=$((n+1)); check "$var" "$name" "$arch" "$min" "$bid" "$app"
done
if [ "$n" -eq 0 ]; then
  app="$(MAVERICKS_BUILD_ROOT="$t" sh "$ROOT/build/build-updater.sh" native 2> "$t/build.log")" \
    || { tail -40 "$t/build.log"; fail "build/build-updater.sh native did not build"; }
  n=1; check native rust-updater x86_64 10.9 dev.mavergreen.rust.rust.updater "$app"
fi
echo "OK updater-test ($n)"
