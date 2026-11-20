#!/bin/sh
# platform: host-agnostic
#   usage: build-updater.sh native|cross     prints the built .app path
#          Builds the variant's Sparkle updater with the pinned clang22 (fetch_clang22.sh), configured by
#          the runner's cmake on Linux and shipyard-cmake on a Mac.
set -eu
v="${1:?usage: build-updater.sh native|cross}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAVERICKS_ROOT="$ROOT"; export MAVERICKS_ROOT
. "$ROOT/build/msc.sh"
case "$v" in native) short=rust; arch=x86_64; floor=10.9 ;; cross) short=rust-cross; arch=arm64; floor=11.0 ;; *) echo "native|cross" >&2; exit 2 ;; esac
B="${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}/mavergreen-rust-updater-$v"
if [ "$(uname -s)" = Linux ]; then
  SYCM="$(command -v cmake)" || { echo "FATAL: no cmake on PATH" >&2; exit 1; }
else
  # platform: /usr/local/mavergreen/bin reaches PATH only through a login shell's paths.d
  SYCM="$(command -v shipyard-cmake || echo /usr/local/mavergreen/bin/shipyard-cmake)"
fi
CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22")"
sy="$(dirname "$SHIPYARD_SCRIPTS")"
rm -rf "$B"
"$SYCM" -S "$ROOT" -B "$B" -DRUST_VARIANT="$v" -DCMAKE_OSX_ARCHITECTURES="$arch" \
  -DCMAKE_TOOLCHAIN_FILE="$sy/MavericksToolchain.cmake" -DMavericksShipyard_DIR="$sy" \
  -DCMAKE_OBJC_COMPILER="$CL/bin/clang" -DCMAKE_OBJC_COMPILER_TARGET="$arch-apple-macos$floor" \
  -DCMAKE_OBJC_FLAGS=--no-default-config -DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld >&2
"$SYCM" --build "$B" >&2
app="$(find "$B" -maxdepth 3 -name "$short-updater.app" -type d | head -1)"
[ -n "$app" ] || { echo "FATAL: no $short-updater.app under $B" >&2; exit 1; }
[ "$app" = "$B/$short-updater.app" ] || { rm -rf "$B/$short-updater.app"; cp -pR "$app" "$B/$short-updater.app"; }
echo "$B/$short-updater.app"
