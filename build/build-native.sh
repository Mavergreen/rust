#!/bin/sh
# platform: macOS-only -- x.py drives Apple toolchains; otool/install_name_tool in relocate_prefix
#   usage: build-native.sh
#          Stages the native (x86_64, runs on 10.9) toolchain at $NATIVE_STAGE_ROOT$NATIVE_PREFIX.
#          On a modern Mac it cross-hosts (build=aarch64, host=x86_64); on 10.9 it builds natively.
# spec: docs/superpowers/specs/2026-09-25-rust-plan3a-conformance-design.md "Build recipe"
set -eu
RUST_VARIANT=native; export RUST_VARIANT
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/versions.sh"; . "$HERE/lib-rust.sh"
export COPYFILE_DISABLE=1
JOBS="$(mavericks_build_jobs)"
STAGE="$NATIVE_STAGE_ROOT$NATIVE_PREFIX"
MODE="$(sh "$SHIPYARD_SCRIPTS/mavericks_mode.sh")"

if staged_complete "$STAGE"; then echo ">> already staged at $STAGE"; exit 0; fi

case "$MODE" in
  cross)  [ "$(uname -m)" = arm64 ] || { echo "FATAL: cross-hosting needs an arm64 build machine (got $(uname -m))" >&2; exit 1; }
          BUILD_TRIPLE=aarch64-apple-darwin; CLANG_VARIANT=cross ;;
  native) BUILD_TRIPLE=x86_64-apple-darwin;  CLANG_VARIANT=native ;;
  *) echo "FATAL: mavericks_mode.sh said '$MODE'" >&2; exit 1 ;;
esac
export CLANG_VARIANT
mkdir -p "$WORK"
CLANGDIR="$(sh "$HERE/fetch-clang.sh")"
SDK="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")"; mkdir -p "$CLANGDIR/SDKs"; ln -sfn "$SDK" "$CLANGDIR/SDKs/MacOSX10.9.sdk"
POLY_A="$(sh "$HERE/fetch-legacy-support.sh")"
SRC="$(sh "$HERE/fetch-rust-src.sh")"
augment_shim "$POLY_A" "$CLANGDIR"

STAGE0=""
if [ "$MODE" = native ]; then STAGE0="$(sh "$HERE/fetch-stage0-onbox.sh" "$CLANGDIR" "$POLY_A")"; fi
write_bootstrap_toml "$SRC" "$NATIVE_PREFIX" "$BUILD_TRIPLE" "$TARGET_TRIPLE" "$CLANGDIR" $STAGE0
write_x86_cmake_toolchain "$WORK/x86_64-10.9.cmake" "$SDK"
CMAKE_BIN="$(cmake_shim_dir "$WORK/cmake-bin")"

# platform: the cmake crate (which bootstrap drives LLVM through) reads
#           CMAKE_TOOLCHAIN_FILE_<target, dashes as underscores> before CMAKE_TOOLCHAIN_FILE
( cd "$SRC" && PATH="$CMAKE_BIN:$PATH" CMAKE="$CMAKE_BIN/cmake" \
    DESTDIR="$NATIVE_STAGE_ROOT" \
    MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    CMAKE_TOOLCHAIN_FILE_x86_64_apple_darwin="$WORK/x86_64-10.9.cmake" \
    PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig PKG_CONFIG_PATH= \
    CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER="$CLANGDIR/bin/clang++" \
    python3 x.py install -j "$JOBS" )

staged_complete "$STAGE" || { echo "FATAL: x.py install did not stage every tool under $STAGE" >&2; exit 1; }
mkdir -p "$STAGE/lib/rustlib/$TARGET_TRIPLE/lib"
cp -f "$POLY_A" "$STAGE/lib/rustlib/$TARGET_TRIPLE/lib/libMacportsLegacySupport.a"
wrap_rustc "$STAGE" always
prune_proc_macro_dylibs "$STAGE"
relocate_prefix "$STAGE" "$CLANGDIR"
sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$STAGE/bin/rustc.bin"
sh "$HERE/verify-relocatable.sh" "$STAGE"
echo ">> native ($MODE) staged at $STAGE"
