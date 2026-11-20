#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
t="$(mktemp -d "${TMPDIR:-/tmp}/no-apple-host-tools.XXXXXX")"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; exit 1; }
S="$ROOT/build/assert-no-apple-host-tools.sh"
printf 'clang22/bin/clang++ -isysroot sdk\nld64.lld -o out\n' > "$t/good.log"
sh "$S" "$t/good.log" > "$t/out" 2>&1 || { cat "$t/out"; fail "a log naming only clang22's tools passes"; }
for bad in 'xcrun --show-sdk-path' '/usr/bin/clang -v' 'pkgutil --expand x.pkg'; do
  printf 'ok line\n%s\n' "$bad" > "$t/bad.log"
  if sh "$S" "$t/good.log" "$t/bad.log" > "$t/out" 2>&1; then fail "a log naming '$bad' fails"; fi
  grep -q "bad.log:2:" "$t/out" || { cat "$t/out"; fail "the failure names the log and line of '$bad'"; }
done
if sh "$S" "$t/missing.log" > "$t/out" 2>&1; then fail "a missing log fails: a step that never ran proves nothing"; fi
if sh "$S" > "$t/out" 2>&1; then fail "no log is a usage error"; fi
echo "OK no-apple-host-tools-test"
