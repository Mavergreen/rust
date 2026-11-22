#!/bin/sh
# platform: host-agnostic
#   usage: build-cross.sh
#          Stages the cross toolchain (runs on arm64 macOS, targets x86_64 10.9) at
#          $CROSS_STAGE_ROOT$CROSS_PREFIX. On Linux it cross-hosts (build=x86_64-unknown-linux-gnu,
#          host=aarch64-apple-darwin); on an Apple Silicon Mac it builds on aarch64-apple-darwin.
set -eu
RUST_VARIANT=cross; export RUST_VARIANT
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"
. "$HERE/lib-rust.sh"
export_source_date_epoch
: "${SHIPYARD_SCRIPTS:?need shipyard}"
export COPYFILE_DISABLE=1
JOBS="$(mavericks_build_jobs)"
STAGE_ROOT="$CROSS_STAGE_ROOT"; STAGE="$STAGE_ROOT$CROSS_PREFIX"

if staged_complete "$STAGE" && stage_is_current "$WORK/staged.stamp" cross; then
  echo ">> already staged at $STAGE"; exit 0
fi
rm -f "$WORK/staged.stamp"; rm -rf "$STAGE_ROOT"

if [ "$(uname -s)" = Linux ]; then
  BUILD_TRIPLE=x86_64-unknown-linux-gnu
else
  [ "$(uname -m)" = arm64 ] || { echo "FATAL: the cross toolchain builds on Linux or an arm64 Mac (got $(uname -s) $(uname -m))" >&2; exit 1; }
  BUILD_TRIPLE=aarch64-apple-darwin
fi

echo "== fetch inputs =="
mkdir -p "$WORK"
C22="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$CLANG_PIN_DIR")"
CLANGDIR="$(clang_work_copy "$C22")"; export CLANGDIR; macho_tools
RECAULK_A="$(fetch_recaulk)"
MAKE_BIN="$(fetch_make)"
SRC="$(sh "$HERE/fetch-rust-src.sh")"

echo "== populate clang-22's 10.9 SDK (stripped from its .pkg, fetched at first use) =="
SDK="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")"
populate_clang_sdk "$CLANGDIR" "$SDK"

echo "== rust's Recaulk pin is authoritative for rustc and cargo too =="
install_recaulk_into_clang "$RECAULK_A" "$CLANGDIR"

STAGE0=""
[ "$BUILD_TRIPLE" != x86_64-unknown-linux-gnu ] || STAGE0="$(sh "$HERE/fetch-stage0.sh" "$CLANGDIR" "$RECAULK_A")"
linux_host_compilers "$CLANGDIR"

echo "== configure bootstrap.toml =="
# spec: shipyard docs/superpowers/specs/2026-09-24-sdk-pinning-design.md, decision 1 --
#       the arm64 half this pkg installs records the pinned 11.3 SDK, minos 11.0
ARM_SDK="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch arm64)"
mkdir -p "$WORK/bin"
write_pinned_cc "$WORK/bin/cc-arm64-pinned" "$ARM_SDK" "$CLANGDIR"
write_pinned_cc "$WORK/bin/c++-arm64-pinned" "$ARM_SDK" "$CLANGDIR" clang++
write_arm64_cmake_toolchain "$WORK/aarch64-11.0.cmake" "$(cd "$SHIPYARD_SCRIPTS/.." && pwd)/MavericksToolchain.cmake" "$CLANGDIR"
ARM64_CC="$WORK/bin/cc-arm64-pinned" ARM64_CXX="$WORK/bin/c++-arm64-pinned" ARM64_LINKER="$WORK/bin/cc-arm64-pinned" \
  write_bootstrap_toml "$SRC" "$CROSS_PREFIX" "$BUILD_TRIPLE" aarch64-apple-darwin "$CLANGDIR" $STAGE0
pin_linux_build_sdk "$BUILD_TRIPLE" "$SDK"
CMAKE_BIN="$(cmake_shim_dir "$WORK/cmake-bin")"

echo "== x.py install (arm64 host and target $TARGET_TRIPLE via clang-22; LLVM from source) =="
# platform: pkgsrc's pkg-config pc_path leads with /opt/pkg/lib/pkgconfig, where cargo's *-sys crates
#           find libgit2, zlib and libcurl
# platform: clang-22 defaults to an x86_64/10.9 target
( cd "$SRC" && \
  PATH="$MAKE_BIN:$CMAKE_BIN:$PATH" CMAKE="$CMAKE_BIN/cmake" \
  CMAKE_TOOLCHAIN_FILE_aarch64_apple_darwin="$WORK/aarch64-11.0.cmake" \
  CFLAGS_aarch64_apple_darwin="--target=arm64-apple-macos11.0 -isysroot $ARM_SDK -mmacosx-version-min=11.0" \
  CXXFLAGS_aarch64_apple_darwin="--target=arm64-apple-macos11.0 -isysroot $ARM_SDK -mmacosx-version-min=11.0" \
  DESTDIR="$STAGE_ROOT" \
  PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig \
  PKG_CONFIG_PATH= \
  CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER="$CLANGDIR/bin/clang++" \
  python3 x.py install -j "$JOBS" )

staged_complete "$STAGE" || { echo "FATAL: x.py install did not stage every tool under $STAGE" >&2; exit 1; }

echo "== bundle Recaulk + wrap rustc (target-gated) =="
mkdir -p "$STAGE/lib/rustlib/$TARGET_TRIPLE/lib"
cp -f "$RECAULK_A" "$STAGE/lib/rustlib/$TARGET_TRIPLE/lib/librecaulk.a"
wrap_rustc "$STAGE" gated
wrap_linking_tool "$STAGE" clippy-driver gated
prune_proc_macro_dylibs "$STAGE"

echo "== relocate (bundle runtimes, rewrite rpaths) =="
rewrite_install_records "$STAGE_ROOT" "$STAGE"
relocate_prefix "$STAGE" "$CLANGDIR"

guard_prefix "$STAGE"
sh "$HERE/verify-relocatable.sh" "$STAGE"
( PATH="$MAKE_BIN:$CMAKE_BIN:$PATH"; MAKE="$MAKE_BIN/make"; CMAKE="$CMAKE_BIN/cmake"
  record_build_tools "$STAGE_ROOT/build-tools.txt" )
stage_stamp cross > "$WORK/staged.stamp"
echo ">> staged cross toolchain at $STAGE"
arm="$(sysctl -n hw.optional.arm64 2>/dev/null)" || arm=0
[ "$(uname -s)" != Darwin ] || [ "$arm" != 1 ] || "$STAGE/bin/rustc" --version
