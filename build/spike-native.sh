#!/bin/sh
# SPIKE (Plan 2, Phase A): build an x86_64/10.9 NATIVE rustc via Rosetta on an arm64 builder. Success =
# a stage2 x86_64 rustc that passes the compat guard and whose output runs on real 10.9. Reuses Plan 1's
# fetched inputs under $WORK. This is a spike: if it can't produce a sound stage2, the Plan 2 decision
# gate falls back to native-bootstrap/rust.sh on the real 10.9 box. Do NOT relax any gate to force green.
#
# Rosetta model: we set [build] build = x86_64-apple-darwin. x.py (arm64 python) downloads the pinned
# x86_64 stage0 and, when it EXECUTES the x86_64 stage0/1/2 rustc, macOS runs them under Rosetta
# transparently -- no `arch -x86_64` wrapper needed on python (Tahoe's python3 is arm64-only anyway).
# The C compiler stays the arm64 cross clang-22 (runs natively, targets x86_64/10.9); a Rosetta x86_64
# process shelling out to an arm64 clang is fine. If bootstrap refuses the build/host arch mismatch, the
# brief's fallback is `arch -x86_64` with a universal python (/usr/bin/python3).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/versions.sh"; . "$HERE/lib-rust.sh"
: "${MSC_SCRIPTS:?need shared-cmake}"; export COPYFILE_DISABLE=1
JOBS="$(mavericks_build_jobs)"
NATIVE_STAGE_ROOT="$WORK/stage-native"; STAGE="$NATIVE_STAGE_ROOT$NATIVE_PREFIX"

if [ -x "$STAGE/bin/rustc" ] && [ -x "$STAGE/bin/cargo" ]; then
  echo ">> already staged at $STAGE"; "$STAGE/bin/rustc" --version; exit 0
fi

echo "== fetch/prepare inputs (reused from Plan 1 where cached) =="
CLANGDIR="$(sh "$HERE/fetch-clang.sh")"
SDK="$(sh "$MSC_SCRIPTS/fetch_sdk.sh")"; mkdir -p "$CLANGDIR/SDKs"; ln -sfn "$SDK" "$CLANGDIR/SDKs/MacOSX10.9.sdk"
POLY_A="$(sh "$HERE/fetch-legacy-support.sh")"
SRC="$(sh "$HERE/fetch-rust-src.sh")"
augment_shim "$POLY_A" "$CLANGDIR"        # same CCRandomGenerateBytes backfill as the cross build

echo "== configure bootstrap.toml (native x86_64/10.9; CMake pinned to the 10.9 SDK) =="
write_bootstrap_toml_native "$SRC" "$NATIVE_PREFIX" "$CLANGDIR" "$SDK"

echo "== x.py install (build==host==target x86_64-apple-darwin; x86_64 stages run under Rosetta) =="
# MACOSX_DEPLOYMENT_TARGET=10.9 is CORRECT here (host IS 10.9) -- counters the cc crate's host-derived
# -mmacosx-version-min for Rust's C deps. (Cross dropped it because there the host was arm64/modern.)
( cd "$SRC" && DESTDIR="$NATIVE_STAGE_ROOT" \
    MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER="$CLANGDIR/bin/clang++" \
    python3 x.py install -j "$JOBS" )

[ -x "$STAGE/bin/rustc" ] || { echo "SPIKE FAIL: no native rustc at $STAGE/bin/rustc" >&2; exit 1; }

echo "== bundle polyfill + wrap rustc (unconditional; native target IS 10.9) =="
mkdir -p "$STAGE/lib/rustlib/$TARGET_TRIPLE/lib"
cp -f "$POLY_A" "$STAGE/lib/rustlib/$TARGET_TRIPLE/lib/libMacportsLegacySupport.a"
wrap_rustc_native "$STAGE"

echo "== relocate =="
relocate_prefix "$STAGE" "$CLANGDIR"

echo "== guard the staged compiler binary (x86_64, min-10.9, NO post-10.9 undefined imports) =="
# DEFAULT guard (no REQUIRE_DEFINED): rustc.bin uses far more of std than a hello -- Mutex, etc. The
# guard's default denylist rejects post-10.9 symbols (_clock_gettime, _os_unfair_lock_*, _os_log*, ...)
# left as UNDEFINED imports. Anything it flags is a symbol the polyfill/shim must also back-fill for the
# NATIVE compiler to run on 10.9 (native-bootstrap/rust.sh's polyfill covered os_unfair_lock et al. --
# that set is the reference for what the native variant may still need beyond the cross build's).
sh "$MSC_SCRIPTS/assert_binary_compatible.sh" "$STAGE/bin/rustc.bin"

echo ">> native staged at $STAGE"
"$STAGE/bin/rustc" --version   # runs under Rosetta on the arm64 builder
