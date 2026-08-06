#!/bin/sh
# Cross-build the Rust toolchain: arm64 host rustc/cargo that TARGETS x86_64-apple-darwin @ 10.9,
# built with the clang-22 cross toolchain + the macports-legacy-support shim. Staged under
# $WORK/stage$CROSS_PREFIX via DESTDIR. Idempotent-ish: skips the heavy x.py step if already staged.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"
. "$HERE/lib-rust.sh"
: "${MSC_SCRIPTS:?need shared-cmake}"
export COPYFILE_DISABLE=1
JOBS="$(mavericks_build_jobs)"
STAGE_ROOT="$WORK/stage"; STAGE="$STAGE_ROOT$CROSS_PREFIX"

if [ -x "$STAGE/bin/rustc" ] && [ -x "$STAGE/bin/cargo" ]; then
  echo ">> already staged at $STAGE"; exit 0
fi

echo "== fetch inputs =="
CLANGDIR="$(sh "$HERE/fetch-clang.sh")"
POLY_A="$(sh "$HERE/fetch-legacy-support.sh")"
SRC="$(sh "$HERE/fetch-rust-src.sh")"

echo "== configure bootstrap.toml =="
write_bootstrap_toml "$SRC" "$CROSS_PREFIX" "$CLANGDIR"

echo "== x.py install (host arm64, target $TARGET_TRIPLE; LLVM from source via clang-22) =="
# cmake>=3.20 + ninja must be on PATH for the LLVM build. clang-22 first so its cc/linker win.
# DESTDIR stages the install under $STAGE_ROOT so packaging can pick it up without root.
( cd "$SRC" && \
  PATH="$CLANGDIR/bin:$PATH" \
  DESTDIR="$STAGE_ROOT" \
  CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER="$CLANGDIR/bin/clang++" \
  MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
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
