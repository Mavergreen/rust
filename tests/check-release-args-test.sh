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
t="$(mktemp -d "${TMPDIR:-/tmp}/check-release.XXXXXX")"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/rel"
printf '#!/bin/sh\necho called > "%s/sudo-called"\n' "$t" > "$t/bin/sudo"; chmod +x "$t/bin/sudo"
echo pkg > "$t/rel/rust-1.95.0-mavericks.1.pkg"
echo "0000  rust-other.pkg" > "$t/rel/SHA256SUMS"
set +e; out="$(PATH="$t/bin:$PATH" MAVERICKS_CHECK_OS=10.9.5 MAVERICKS_RELEASE_BASE="file://$t/rel" sh "$S" 1.95.0-mavericks.1 2>&1)"; rc=$?; set -e
[ "$rc" != 0 ] || fail "a pkg that SHA256SUMS does not list must fail the check: $out"
[ ! -f "$t/sudo-called" ] || fail "an unverified pkg must never reach sudo installer (conventions: unverified must never look like a pass)"
echo "OK check-release-args-test"
