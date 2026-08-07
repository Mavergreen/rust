#!/bin/sh
# Package the staged cross toolchain as a component .pkg. NO 10.9.5 install floor: this pkg RUNS on
# modern macOS (arm64) and only TARGETS 10.9 (golang/clang cross-pkg precedent). Emits build-info-cross.txt.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"
: "${SHIPYARD_SCRIPTS:?need shipyard}"
export COPYFILE_DISABLE=1
STAGE_ROOT="$WORK/stage"; STAGE="$STAGE_ROOT$CROSS_PREFIX"
[ -x "$STAGE/bin/rustc" ] || { echo "FATAL: run build-cross.sh first" >&2; exit 1; }
VER="$(sh "$SHIPYARD_SCRIPTS/resolve-version.sh" "$(sh "$SHIPYARD_SCRIPTS/release-mode.sh")")"
DIST="$HERE/../dist"; mkdir -p "$DIST"
PAYLOAD="$STAGE_ROOT"     # DESTDIR root; contains .$CROSS_PREFIX
NAME="mavericks-rust-cross-$VER.pkg"
STAGING_OUT="$WORK/out"; mkdir -p "$STAGING_OUT"
OUT="$STAGING_OUT/$NAME"

# AppleDouble sidecars an NFS stage sprays would otherwise ship as payload.
find "$PAYLOAD" -name '._*' -delete 2>/dev/null || true

pkg="$(sh "$SHIPYARD_SCRIPTS/build_component_pkg.sh" \
  --root "$PAYLOAD" \
  --identifier "$CROSS_IDENTIFIER" \
  --version "$VER" \
  --install-location "/" \
  --out "$OUT")"
mv "$pkg" "$DIST/$NAME"
rm -f "$STAGING_OUT/$(basename "$NAME" .pkg)-components.plist"
pkg="$DIST/$NAME"
echo "built $pkg"

# What this variant was built FROM (Plan 3 conformance compares variants; a reader can see it now).
CLANG_TAG="$(tr -d ' \t\n' < "$CLANG_PIN_FILE")"
sh "$SHIPYARD_SCRIPTS/build-info.sh" "$DIST/build-info-cross.txt" \
  variant=cross arch=arm64 prefix="$CROSS_PREFIX" pkg="$(basename "$pkg")" identifier="$CROSS_IDENTIFIER" \
  rust="$RUST_VERSION" clang="$CLANG_TAG" legacy_support="$MLS_VERSION" target="$TARGET_TRIPLE"
cat "$DIST/build-info-cross.txt"
