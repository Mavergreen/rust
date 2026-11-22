#!/bin/sh
# platform: host-agnostic
#   usage: build-linux.sh
#          Stages the Linux-hosted toolchain at $LINUX_STAGE_ROOT$LINUX_PREFIX: rustc and cargo that run
#          on x86_64 Linux and target x86_64-unknown-linux-gnu and x86_64-apple-darwin (10.9). It runs on
#          x86_64 Linux, inside clang-22's pinned base image (build/linux/Dockerfile adds the build's
#          own tools), so what it ships runs on the family's glibc floor.
# spec: .superpowers/plans/2026-10-24-macos-runner-exit/06-rust-and-codex-cli.md D1, D2, D3 and D7 (shipyard)
set -eu
RUST_VARIANT=linux; export RUST_VARIANT
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/versions.sh"; . "$HERE/lib-rust.sh"
export_source_date_epoch
: "${SHIPYARD_SCRIPTS:?need shipyard}"
[ "$(uname -s)/$(uname -m)" = Linux/x86_64 ] \
  || { echo "FATAL: the Linux-hosted toolchain builds on x86_64 Linux (got $(uname -s) $(uname -m))" >&2; exit 1; }
JOBS="$(mavericks_build_jobs)"
BUILD_TRIPLE=x86_64-unknown-linux-gnu
STAGE_ROOT="$LINUX_STAGE_ROOT"; STAGE="$STAGE_ROOT$LINUX_PREFIX"

if staged_complete "$STAGE" && stage_is_current "$WORK/staged.stamp" linux; then echo ">> already staged at $STAGE"; exit 0; fi
rm -f "$WORK/staged.stamp"; rm -rf "$STAGE_ROOT"

echo "== fetch inputs =="
mkdir -p "$WORK"
C22="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$CLANG_PIN_DIR")"
CLANGDIR="$(clang_work_copy "$C22")"; export CLANGDIR; macho_tools
SDK="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")"; populate_clang_sdk "$CLANGDIR" "$SDK"
RECAULK_A="$(fetch_recaulk)"
MAKE_BIN="$(fetch_make)"
SRC="$(sh "$HERE/fetch-rust-src.sh")"
install_recaulk_into_clang "$RECAULK_A" "$CLANGDIR"
STAGE0="$(sh "$HERE/fetch-stage0.sh" "$CLANGDIR" "$RECAULK_A")"
linux_host_compilers "$CLANGDIR"

echo "== configure bootstrap.toml (host $BUILD_TRIPLE, targets $BUILD_TRIPLE and $TARGET_TRIPLE) =="
write_bootstrap_toml "$SRC" "$LINUX_PREFIX" "$BUILD_TRIPLE" "$BUILD_TRIPLE" "$CLANGDIR" "$STAGE0"
pin_linux_build_sdk "$BUILD_TRIPLE" "$SDK"
CMAKE_BIN="$(cmake_shim_dir "$WORK/cmake-bin")"

echo "== x.py install (LLVM from source, X86 only) =="
( cd "$SRC" && PATH="$MAKE_BIN:$CMAKE_BIN:$PATH" CMAKE="$CMAKE_BIN/cmake" \
    DESTDIR="$STAGE_ROOT" \
    PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig PKG_CONFIG_PATH= \
    CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER="$CLANGDIR/bin/clang++" \
    python3 x.py install -j "$JOBS" )

staged_complete "$STAGE" || { echo "FATAL: x.py install did not stage every tool under $STAGE" >&2; exit 1; }

echo "== bundle Recaulk + wrap rustc (target-gated) =="
mkdir -p "$STAGE/lib/rustlib/$TARGET_TRIPLE/lib"
cp -f "$RECAULK_A" "$STAGE/lib/rustlib/$TARGET_TRIPLE/lib/librecaulk.a"
wrap_rustc "$STAGE" gated
wrap_linking_tool "$STAGE" clippy-driver gated

echo "== audit: Linux ELF on the glibc floor, $TARGET_TRIPLE Mach-O at 10.9 =="
audit_linux_elf "$STAGE"
find "$STAGE/lib/rustlib/$TARGET_TRIPLE/lib" -type f -name '*.dylib' > "$WORK/darwin-dylibs"
[ -s "$WORK/darwin-dylibs" ] || { echo "FATAL: no $TARGET_TRIPLE dylib under $STAGE/lib/rustlib -- nothing guarded" >&2; exit 1; }
tr '\n' '\0' < "$WORK/darwin-dylibs" | MAVERICKS_ALLOW_ARCHS=x86_64 xargs -0 sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh"
sh "$HERE/verify-relocatable.sh" "$STAGE"
( PATH="$MAKE_BIN:$CMAKE_BIN:$PATH"; MAKE="$MAKE_BIN/make"; CMAKE="$CMAKE_BIN/cmake"
  record_build_tools "$STAGE_ROOT/build-tools.txt" )
stage_stamp linux > "$WORK/staged.stamp"
echo ">> Linux-hosted toolchain staged at $STAGE"
"$STAGE/bin/rustc" -vV
