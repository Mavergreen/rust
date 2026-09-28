#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
t="$(mktemp -d "${TMPDIR:-/tmp}/stage0.XXXXXX")"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; exit 1; }
[ -f "$ROOT/build/fetch-stage0-onbox.sh" ] || fail "build/fetch-stage0-onbox.sh missing"
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"; export TARGET_TRIPLE MACOS_MIN REPO_ROOT
. "$ROOT/build/lib-rust.sh"
command -v write_stage0_wrappers >/dev/null || fail "lib-rust.sh has no write_stage0_wrappers"
write_stage0_wrappers "$t/s0" "$t/dist"
for b in rustc cargo; do
  w="$t/s0/bin/$b"; [ -x "$w" ] || fail "$b wrapper not executable"
  grep -qx "export DYLD_INSERT_LIBRARIES=\"$t/s0/libMavericksLegacySupport.dylib\"" "$w" || fail "$b: injects the wrong dylib"
  grep -qx 'export DYLD_FORCE_FLAT_NAMESPACE=1' "$w" || fail "$b: flat namespace is what lets the dylib satisfy the prebuilt's missing-on-10.9 imports"
done
grep -q "exec \"$t/dist/rustc/bin/rustc\"" "$t/s0/bin/rustc" || fail "rustc wrapper execs the wrong binary"
grep -q "exec \"$t/dist/cargo/bin/cargo\"" "$t/s0/bin/cargo" || fail "cargo wrapper execs the wrong binary"
echo "OK stage0-onbox-test"
