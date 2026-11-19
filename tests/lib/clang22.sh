#!/bin/sh
# platform: host-agnostic
#   usage: . "$ROOT/tests/lib/clang22.sh"   (sourced by a test, after ROOT is set; needs SHIPYARD_SCRIPTS)
#          Exports CLANGDIR, shipyard's clang22 for components/clang22 on this host (the Linux archive on
#          Linux), and S9, the pinned 10.9 SDK, and defines fixture_cc, which links an x86_64 10.9 Mach-O
#          with them and no clang.cfg. Exits 77 only when no clang22 or SDK can be fetched.
CLANGDIR="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22")" \
  || { echo "no clang22 could be fetched -- skipping"; exit 77; }
S9="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")" || { echo "no 10.9 SDK could be fetched -- skipping"; exit 77; }
export CLANGDIR S9
fixture_cc() {
  "$CLANGDIR/bin/clang" --no-default-config -Wno-unused-command-line-argument -fuse-ld=lld \
    --ld-path="$CLANGDIR/bin/ld64.lld" -target x86_64-apple-macos10.9 -isysroot "$S9" \
    -Wl,-headerpad_max_install_names "$@"
}
