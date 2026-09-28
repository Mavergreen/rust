#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
fail() { echo "FAIL $1"; exit 1; }
[ -f "$ROOT/build/upstream-release-notes-url.sh" ] || fail "build/upstream-release-notes-url.sh missing (check 11: a new upstream links upstream's notes)"
U="$(tr -d ' \t\n' < "$ROOT/UPSTREAM_VERSION")"
out="$(sh "$ROOT/build/upstream-release-notes-url.sh" "$U")"
[ "$out" = "https://github.com/rust-lang/rust/releases/tag/$U" ] || fail "want exactly one URL for $U, got: $out"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "upstream-notes.sh requires exactly one line"
! sh "$ROOT/build/upstream-release-notes-url.sh" 2>/dev/null || fail "no argument must be a usage error"
echo "OK upstream-notes-url-test"
