#!/bin/sh
# Package the staged NATIVE toolchain as a product .pkg WITH the hard 10.9.5 install floor. This variant
# RUNS on 10.9, so the floor is a REQUIREMENT -- the mirror of the cross pkg's deliberate absence, and a
# bare component pkg cannot express it (an OS floor is a productbuild/Distribution concept). Emits
# build-info-native.txt, which MUST agree with build-info-cross.txt on rust/clang/legacy_support/target.
set -eu
RUST_VARIANT=native; export RUST_VARIANT
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"
: "${SHIPYARD_SCRIPTS:?need shipyard}"
export COPYFILE_DISABLE=1
STAGE_ROOT="$NATIVE_STAGE_ROOT"; STAGE="$STAGE_ROOT$NATIVE_PREFIX"
[ -x "$STAGE/bin/rustc" ] || { echo "FATAL: run build-native.sh first" >&2; exit 1; }
VER="$(sh "$SHIPYARD_SCRIPTS/resolve-version.sh" "$(sh "$SHIPYARD_SCRIPTS/release-mode.sh")")"
DIST="$HERE/../dist"; mkdir -p "$DIST"
PAYLOAD="$STAGE_ROOT"     # DESTDIR root; contains .$NATIVE_PREFIX
NAME="mavericks-rust-native-$VER.pkg"
OUT="$WORK/out"; mkdir -p "$OUT"

# AppleDouble sidecars an NFS/shared stage sprays would otherwise ship as payload.
find "$PAYLOAD" -name '._*' -delete 2>/dev/null || true

comp="$(sh "$SHIPYARD_SCRIPTS/build_component_pkg.sh" \
  --root "$PAYLOAD" \
  --identifier "$NATIVE_IDENTIFIER" \
  --version "$VER" \
  --install-location "/" \
  --out "$OUT/mavericks-rust-native-component.pkg")"

# Wrap with the 10.9.5 floor (this variant runs on 10.9). No --require-scripts: no postinstall/updater
# in Plan 2 (the Sparkle updater is Plan 3).
sh "$SHIPYARD_SCRIPTS/set_install_floor.sh" \
  --identifier "$NATIVE_IDENTIFIER" \
  --title "Rust for Mavericks $VER" \
  --component "$comp" \
  --out "$DIST/$NAME" \
  --host-arch x86_64
rm -f "$OUT/mavericks-rust-native-component.pkg"
echo "built $DIST/$NAME"

# What this variant was built FROM. Conformance compares any key appearing in more than one variant, so
# rust/clang/legacy_support/target MUST match build-info-cross.txt; variant/arch/prefix/pkg/identifier differ.
CLANG_TAG="$(tr -d ' \t\n' < "$CLANG_PIN_FILE")"
sh "$SHIPYARD_SCRIPTS/build-info.sh" "$DIST/build-info-native.txt" \
  variant=native arch=x86_64 prefix="$NATIVE_PREFIX" pkg="$NAME" identifier="$NATIVE_IDENTIFIER" \
  rust="$RUST_VERSION" clang="$CLANG_TAG" legacy_support="$MLS_VERSION" target="$TARGET_TRIPLE"
cat "$DIST/build-info-native.txt"
