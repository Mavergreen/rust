#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"
RUST_VERSION=1.95.0; MLS_VERSION=1.5.2-mavericks.5; CLANG_PIN_FILE="$ROOT/components/clang/version"
export TARGET_TRIPLE MACOS_MIN REPO_ROOT RUST_VERSION MLS_VERSION CLANG_PIN_FILE
. "$ROOT/build/lib-rust.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/stamp.XXXXXX")"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; exit 1; }
! stage_is_current "$t/none.stamp" native || fail "no stamp means the stage is not current (a failure after x.py leaves one that looks complete)"
stage_stamp native > "$t/s.stamp"
stage_is_current "$t/s.stamp" native || fail "a stamp written now must read as current"
! stage_is_current "$t/s.stamp" cross || fail "a native stamp must not vouch for the cross stage"
( MLS_VERSION=1.5.2-mavericks.6; ! stage_is_current "$t/s.stamp" native ) \
  || fail "bumping a pin must invalidate the stage (else build-info claims the new pin over an old build)"
( RUST_VERSION=1.96.0; ! stage_is_current "$t/s.stamp" native ) || fail "bumping Rust must invalidate the stage"
grep -q "lib-rust.sh" "$t/s.stamp" || fail "the stamp must cover the recipe (lib-rust.sh), whose post-x.py steps shape the stage"
echo "OK stamp-test"
