#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$HERE/target/target-core2.sh"
fail() { echo "FAIL $1"; exit 1; }
[ -f "$T" ] || fail "tests/target/target-core2.sh is missing"
set +e; out="$(sh "$T" 2>&1)"; rc=$?; set -e
[ "$rc" = 2 ] || fail "with no rustc named it checks nothing, so it refuses rather than passing (exit 2, got $rc): $out"
grep -q 'target/target-core2.sh" "$P/bin/rustc"' "$HERE/linux-smoke.sh" || fail "linux-smoke runs it with the Linux tarball's rustc"
grep -q 'target/target-core2.sh" "$S/bin/rustc"' "$HERE/smoke-native.sh" || fail "smoke-native's executing half runs it with the native stage's rustc"
echo "PASS target-core2-test"
