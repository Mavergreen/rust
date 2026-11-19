#!/bin/sh
# platform: host-agnostic
#   usage: build-native.sh
#          Stages the native (x86_64, runs on 10.9) toolchain at $NATIVE_STAGE_ROOT$NATIVE_PREFIX.
#          On Linux it cross-hosts (build=x86_64-unknown-linux-gnu, host=x86_64-apple-darwin), on an
#          Apple Silicon Mac too (build=aarch64); on 10.9 it builds natively.
# spec: docs/superpowers/specs/2026-09-25-rust-plan3a-conformance-design.md "Build recipe"
set -eu
RUST_VARIANT=native; export RUST_VARIANT
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/versions.sh"; . "$HERE/lib-rust.sh"
export COPYFILE_DISABLE=1
JOBS="$(mavericks_build_jobs)"
STAGE="$NATIVE_STAGE_ROOT$NATIVE_PREFIX"
MODE="$(sh "$SHIPYARD_SCRIPTS/mavericks_mode.sh")"

if staged_complete "$STAGE" && stage_is_current "$WORK/staged.stamp" native; then echo ">> already staged at $STAGE"; exit 0; fi
rm -f "$WORK/staged.stamp"; rm -rf "$NATIVE_STAGE_ROOT"

case "$MODE" in
  cross)  if [ "$(uname -s)" = Linux ]; then
            BUILD_TRIPLE=x86_64-unknown-linux-gnu
          else
            [ "$(uname -m)" = arm64 ] || { echo "FATAL: cross-hosting from a Mac needs an arm64 build machine (got $(uname -m))" >&2; exit 1; }
            BUILD_TRIPLE=aarch64-apple-darwin
          fi ;;
  native) BUILD_TRIPLE=x86_64-apple-darwin ;;
  *) echo "FATAL: mavericks_mode.sh said '$MODE'" >&2; exit 1 ;;
esac
mkdir -p "$WORK"
C22="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$CLANG_PIN_DIR")"
CLANGDIR="$(clang_work_copy "$C22")"; export CLANGDIR; macho_tools
SDK="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")"; populate_clang_sdk "$CLANGDIR" "$SDK"
RECAULK_A="$(fetch_recaulk)"
MAKE_BIN="$(fetch_make)"
SRC="$(sh "$HERE/fetch-rust-src.sh")"
install_recaulk_into_clang "$RECAULK_A" "$CLANGDIR"

STAGE0=""
if [ "$MODE" = native ] || [ "$BUILD_TRIPLE" = x86_64-unknown-linux-gnu ]; then
  STAGE0="$(sh "$HERE/fetch-stage0.sh" "$CLANGDIR" "$RECAULK_A")"
fi
linux_host_compilers "$CLANGDIR"
write_bootstrap_toml "$SRC" "$NATIVE_PREFIX" "$BUILD_TRIPLE" "$TARGET_TRIPLE" "$CLANGDIR" $STAGE0
write_x86_cmake_toolchain "$WORK/x86_64-10.9.cmake" "$SDK" "$CLANGDIR"
pin_onbox_tools "$BUILD_TRIPLE" "$CLANGDIR" "$SDK"
pin_linux_build_sdk "$BUILD_TRIPLE" "$SDK"
CMAKE_BIN="$(cmake_shim_dir "$WORK/cmake-bin")"

# platform: the cmake crate (which bootstrap drives LLVM through) reads
#           CMAKE_TOOLCHAIN_FILE_<target, dashes as underscores> before CMAKE_TOOLCHAIN_FILE
( cd "$SRC" && PATH="$MAKE_BIN:$CMAKE_BIN:$PATH" CMAKE="$CMAKE_BIN/cmake" \
    DESTDIR="$NATIVE_STAGE_ROOT" \
    MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    CMAKE_TOOLCHAIN_FILE_x86_64_apple_darwin="$WORK/x86_64-10.9.cmake" \
    PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig PKG_CONFIG_PATH= \
    CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER="$CLANGDIR/bin/clang++" \
    python3 x.py install -j "$JOBS" )

staged_complete "$STAGE" || { echo "FATAL: x.py install did not stage every tool under $STAGE" >&2; exit 1; }
mkdir -p "$STAGE/lib/rustlib/$TARGET_TRIPLE/lib"
cp -f "$RECAULK_A" "$STAGE/lib/rustlib/$TARGET_TRIPLE/lib/librecaulk.a"
wrap_rustc "$STAGE" always
wrap_linking_tool "$STAGE" clippy-driver always
prune_proc_macro_dylibs "$STAGE"
relocate_prefix "$STAGE" "$CLANGDIR"
guard_prefix "$STAGE"
sh "$HERE/verify-relocatable.sh" "$STAGE"
stage_stamp native > "$WORK/staged.stamp"
echo ">> native ($MODE) staged at $STAGE"
