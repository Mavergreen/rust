#!/bin/sh
# platform: macOS-only -- x.py drives Apple toolchains; otool/install_name_tool in relocate_prefix
#   usage: build-cross.sh
#          Stages the cross toolchain (runs on arm64 macOS, targets x86_64 10.9) at
#          $CROSS_STAGE_ROOT$CROSS_PREFIX.
set -eu
RUST_VARIANT=cross; export RUST_VARIANT
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"
. "$HERE/lib-rust.sh"
: "${SHIPYARD_SCRIPTS:?need shipyard}"
export COPYFILE_DISABLE=1
JOBS="$(mavericks_build_jobs)"
STAGE_ROOT="$CROSS_STAGE_ROOT"; STAGE="$STAGE_ROOT$CROSS_PREFIX"

if staged_complete "$STAGE"; then
  echo ">> already staged at $STAGE"; exit 0
fi

echo "== fetch inputs =="
CLANGDIR="$(sh "$HERE/fetch-clang.sh")"
POLY_A="$(sh "$HERE/fetch-legacy-support.sh")"
SRC="$(sh "$HERE/fetch-rust-src.sh")"

echo "== populate clang-22's 10.9 SDK (stripped from its .pkg, fetched at first use) =="
# platform: clang-22's pkg ships an empty SDKs/; clang.cfg looks for <bin>/../SDKs/MacOSX10.9.sdk
SDK="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")"
mkdir -p "$CLANGDIR/SDKs"; ln -sfn "$SDK" "$CLANGDIR/SDKs/MacOSX10.9.sdk"

echo "== backfill CCRandomGenerateBytes into the shim (and make MLS_VERSION authoritative) =="
augment_shim "$POLY_A" "$CLANGDIR"

echo "== configure bootstrap.toml =="
write_bootstrap_toml "$SRC" "$CROSS_PREFIX" aarch64-apple-darwin aarch64-apple-darwin "$CLANGDIR"
CMAKE_BIN="$(cmake_shim_dir "$WORK/cmake-bin")"

echo "== x.py install (arm64 host via system clang; target $TARGET_TRIPLE via clang-22; LLVM from source) =="
# platform: pkgsrc's pkg-config pc_path leads with /opt/pkg/lib/pkgconfig, so cargo's *-sys crates
#           linked bin/cargo against /opt/pkg dylibs until PKG_CONFIG_LIBDIR named the system dir only
# platform: clang-22 defaults to an x86_64/10.9 target, so on PATH it would shadow the arm64 host compiler
( cd "$SRC" && \
  PATH="$CMAKE_BIN:$PATH" CMAKE="$CMAKE_BIN/cmake" \
    DESTDIR="$STAGE_ROOT" \
  PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig \
  PKG_CONFIG_PATH= \
  CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER="$CLANGDIR/bin/clang++" \
  python3 x.py install -j "$JOBS" )

staged_complete "$STAGE" || { echo "FATAL: x.py install did not stage every tool under $STAGE" >&2; exit 1; }

echo "== bundle polyfill + wrap rustc (target-gated) =="
mkdir -p "$STAGE/lib/rustlib/$TARGET_TRIPLE/lib"
cp -f "$POLY_A" "$STAGE/lib/rustlib/$TARGET_TRIPLE/lib/libMacportsLegacySupport.a"
wrap_rustc "$STAGE" gated
prune_proc_macro_dylibs "$STAGE"

echo "== relocate (bundle runtimes, rewrite rpaths) =="
relocate_prefix "$STAGE" "$CLANGDIR"

echo ">> staged cross toolchain at $STAGE"
"$STAGE/bin/rustc" --version
