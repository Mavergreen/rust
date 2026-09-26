#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
fail() { echo "FAIL $1"; exit 1; }
S="$ROOT/build/check-release-on-10.9.sh"
[ -f "$S" ] || fail "build/check-release-on-10.9.sh missing"
set +e; out="$(sh "$S" 2>&1)"; rc=$?; set -e
[ "$rc" = 2 ] || fail "no argument: exit 2 (usage), got $rc"
case "$out" in *usage*) : ;; *) fail "no argument must print usage: $out" ;; esac
set +e; out="$(MAVERICKS_CHECK_OS=15.7 sh "$S" 1.95.0-mavericks.1 2>&1)"; rc=$?; set -e
[ "$rc" = 2 ] || fail "off 10.9: exit 2 before touching anything, got $rc"
case "$out" in *10.9*) : ;; *) fail "off 10.9 the refusal must say it needs 10.9: $out" ;; esac
echo "OK check-release-args-test"
