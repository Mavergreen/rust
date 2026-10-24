#!/bin/sh
# platform: macOS-only -- builds a Mach-O with macho_tools' clang-22 and reads it with file(1)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"; export TARGET_TRIPLE MACOS_MIN REPO_ROOT
. "$ROOT/build/versions.sh"; . "$ROOT/build/lib-rust.sh"; macho_tools
t="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/guard.XXXXXX")" && pwd)"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; cat "$t/err" 2>/dev/null; exit 1; }
mkdir -p "$t/p/bin" "$t/p/lib"
printf 'int main(void) { return 0; }\n' > "$t/main.c"
"$MACHO_CC" -o "$t/p/bin/tool" "$t/main.c"
printf '#!/bin/sh\necho "lipo-could-not-read-it" >&2\nexit 1\n' > "$t/broken-lipo"
chmod +x "$t/broken-lipo"

guard_prefix "$t/p" > /dev/null 2> "$t/err" || fail "a 10.9-safe x86_64 prefix must pass the guard"
if LIPO="$t/broken-lipo" guard_prefix "$t/p" > /dev/null 2> "$t/err"; then
  fail "a Mach-O whose arch LIPO cannot name must fail the guard"
fi
grep -q "$t/p/bin/tool" "$t/err" || fail "the failure must name the file LIPO could not read"
grep -q 'lipo-could-not-read-it' "$t/err" || fail "the failure must show what LIPO said about it"
if grep -q 'Is a directory' "$t/err"; then fail "an empty arch must not reach the per-arch file list"; fi
echo "OK guard-test"
