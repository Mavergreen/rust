#!/bin/sh
# platform: macOS-only -- builds a Cocoa app with Apple's toolchain
#   usage: build-updater.sh native|cross     prints the built .app path
set -eu
v="${1:?usage: build-updater.sh native|cross}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAVERICKS_ROOT="$ROOT"; export MAVERICKS_ROOT
. "$ROOT/build/msc.sh"
case "$v" in native) short=rust; arch=x86_64 ;; cross) short=rust-cross; arch=arm64 ;; *) echo "native|cross" >&2; exit 2 ;; esac
B="${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}/mavergreen-rust-updater-$v"
# platform: /usr/local/mavergreen/bin reaches PATH only through a login shell's paths.d
SYCM="$(command -v shipyard-cmake || echo /usr/local/mavergreen/bin/shipyard-cmake)"
# spec: docs/superpowers/specs/2026-09-25-rust-plan3a-conformance-design.md "Goal" -- Renovate
#       config is Plan 3B's; 3A must not scaffold one into the tree.
# platform: a pkgsrc or Homebrew clang can precede /usr/bin on PATH, and RequireAppleClang refuses it
OBJC=/usr/bin/clang "$SYCM" -S "$ROOT" -B "$B" -DRUST_VARIANT="$v" -DCMAKE_OSX_ARCHITECTURES="$arch" \
  -DCMAKE_TOOLCHAIN_FILE="$(dirname "$SHIPYARD_SCRIPTS")/MavericksToolchain.cmake" \
  -DMAVERICKS_NO_RENOVATE_SCAFFOLD=ON >&2
"$SYCM" --build "$B" >&2
app="$(find "$B" -maxdepth 3 -name "$short-updater.app" -type d | head -1)"
[ -n "$app" ] || { echo "FATAL: no $short-updater.app under $B" >&2; exit 1; }
[ "$app" = "$B/$short-updater.app" ] || { rm -rf "$B/$short-updater.app"; ditto "$app" "$B/$short-updater.app"; }
echo "$B/$short-updater.app"
