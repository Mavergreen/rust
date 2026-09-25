#!/bin/sh
# Cross-build the Rust toolchain: arm64 host rustc/cargo that TARGETS x86_64-apple-darwin @ 10.9,
# built with the clang-22 cross toolchain + the macports-legacy-support shim. Staged under
# $WORK/stage$CROSS_PREFIX via DESTDIR. Idempotent-ish: skips the heavy x.py step if already staged.
set -eu
RUST_VARIANT=cross; export RUST_VARIANT
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"
. "$HERE/lib-rust.sh"
: "${SHIPYARD_SCRIPTS:?need shipyard}"
export COPYFILE_DISABLE=1
JOBS="$(mavericks_build_jobs)"
STAGE_ROOT="$CROSS_STAGE_ROOT"; STAGE="$STAGE_ROOT$CROSS_PREFIX"

if [ -x "$STAGE/bin/rustc" ] && [ -x "$STAGE/bin/cargo" ]; then
  echo ">> already staged at $STAGE"; exit 0
fi

echo "== fetch inputs =="
CLANGDIR="$(sh "$HERE/fetch-clang.sh")"
POLY_A="$(sh "$HERE/fetch-legacy-support.sh")"
SRC="$(sh "$HERE/fetch-rust-src.sh")"

echo "== populate clang-22's 10.9 SDK (stripped from its .pkg, fetched at first use) =="
# clang-22 targets x86_64-apple-macos10.9 via clang.cfg -> <bin>/../SDKs/MacOSX10.9.sdk, but its .pkg
# ships an EMPTY SDKs/ (Apple's SDK is not redistributed). fetch_sdk.sh honors the machine's cached SDK.
SDK="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")"
mkdir -p "$CLANGDIR/SDKs"; ln -sfn "$SDK" "$CLANGDIR/SDKs/MacOSX10.9.sdk"

echo "== backfill CCRandomGenerateBytes into the shim (and make MLS_VERSION authoritative) =="
augment_shim "$POLY_A" "$CLANGDIR"

echo "== configure bootstrap.toml =="
write_bootstrap_toml "$SRC" "$CROSS_PREFIX" "$CLANGDIR"

echo "== x.py install (arm64 host via system clang; target $TARGET_TRIPLE via clang-22; LLVM from source) =="
# cmake + ninja come from PATH (pkgsrc /opt/pkg on this box) for the LLVM build; the /opt/pkg leak is
# guarded in bootstrap.toml's [llvm] build-config. Do NOT put clang-22 first on PATH: it defaults to an
# x86_64/10.9 target and would shadow the host compiler for the arm64 host build. clang-22 is referenced
# only by absolute path -- via [target.x86_64-apple-darwin] in bootstrap.toml and the CARGO_TARGET linker.
# DESTDIR stages the install under $STAGE_ROOT so packaging can pick it up without root.
# PKG_CONFIG_LIBDIR is the cargo-side counterpart of [llvm] CMAKE_IGNORE_PREFIX_PATH: cargo builds
# bin/cargo on the HOST, and its *-sys crates (libgit2-sys, libz-sys, curl-sys) probe pkg-config. On a
# pkgsrc box pkg-config is /opt/pkg's, whose default pc_path leads with /opt/pkg/lib/pkgconfig -- so
# they found libgit2.pc/zlib.pc/libcurl.pc there and bin/cargo shipped hard dependencies on
# /opt/pkg/lib/{libgit2,libz,libcurl,libiconv,libunwind}.dylib, which tests/relocatable-test.sh
# rejects. Pointing LIBDIR at the system dir only (and clearing the additive PATH) makes libgit2/libz
# build vendored and curl's force-system-lib-on-osx resolve /usr/lib/libcurl. The cmake guard does not
# cover this: it constrains LLVM's CMake probes, not cargo's.
( cd "$SRC" && \
  DESTDIR="$STAGE_ROOT" \
  PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig \
  PKG_CONFIG_PATH= \
  CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER="$CLANGDIR/bin/clang++" \
  python3 x.py install -j "$JOBS" --host aarch64-apple-darwin --target "aarch64-apple-darwin,$TARGET_TRIPLE" )

[ -x "$STAGE/bin/rustc" ] || { echo "FATAL: x.py install did not produce $STAGE/bin/rustc" >&2; exit 1; }

echo "== bundle polyfill + wrap rustc (target-gated) =="
mkdir -p "$STAGE/lib/rustlib/$TARGET_TRIPLE/lib"
cp -f "$POLY_A" "$STAGE/lib/rustlib/$TARGET_TRIPLE/lib/libMacportsLegacySupport.a"
wrap_rustc_cross "$STAGE"

echo "== relocate (bundle runtimes, rewrite rpaths) =="
relocate_prefix "$STAGE" "$CLANGDIR"

echo ">> staged cross toolchain at $STAGE"
"$STAGE/bin/rustc" --version
