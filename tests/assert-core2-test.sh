#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
A="$ROOT/build/assert-core2.sh"
fail() { echo "FAIL $1"; exit 1; }
[ -f "$A" ] || fail "build/assert-core2.sh is missing"
. "$ROOT/build/versions.sh"; . "$ROOT/build/lib-rust.sh"; . "$ROOT/tests/lib/clang22.sh"; macho_tools
t="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/assert-core2.XXXXXX")" && pwd)"; trap 'rm -rf "$t"' EXIT
cat > "$t/loop.c" <<'C'
void vmin(int *a, const int *b, int n) { for (int i = 0; i < n; i++) { int x = a[i] < b[i] ? a[i] : b[i]; a[i] = x * b[i]; } }
C
cat > "$t/opt.c" <<'C'
#include <smmintrin.h>
__attribute__((target("sse4.1"))) __m128i fastmin(__m128i a, __m128i b) { return _mm_min_epi32(a, b); }
C
cc1() { "$CLANGDIR/bin/clang" --no-default-config --target=x86_64-apple-macos10.9 -O2 -c "$@"; }
prefix() {  # prefix NAME OBJECT...: a prefix whose only rlib holds the objects
  d="$t/$1/lib/rustlib/x86_64-apple-darwin/lib"; mkdir -p "$d" "$t/$1/bin"; shift
  "$CLANGDIR/bin/llvm-ar" rc "$d/libfix.rlib" "$@"
}
cc1 -march=core2 -fembed-bitcode "$t/loop.c" -o "$t/core2.o"
cc1 -march=penryn -fembed-bitcode "$t/loop.c" -o "$t/penryn.o"
cc1 -march=core2 -fembed-bitcode "$t/opt.c" -o "$t/opt.o"
"$CLANGDIR/bin/llvm-objdump" -d "$t/penryn.o" | grep -q pminsd || fail "the penryn fixture must hold SSE4.1, or this test proves nothing"

prefix good "$t/core2.o"
out="$(sh "$A" "$t/good" 2>&1)" || fail "a core2 rlib passes: $out"
case "$out" in "core2: 1 objects, 0 executables clean") : ;; *) fail "a clean run says what it checked: $out" ;; esac

prefix bad "$t/penryn.o"
if out="$(sh "$A" "$t/bad" 2>&1)"; then fail "a penryn rlib fails: $out"; fi
case "$out" in *"core2: "*"libfix.rlib"*" vmin uses p"*"(bitcode)"*) : ;; *) fail "the offender line names the archive, the function, the instruction and the rule: $out" ;; esac

prefix opted "$t/core2.o" "$t/opt.o"
out="$(sh "$A" "$t/opted" 2>&1)" || fail "a function compiled for sse4.1 by its own attribute, in a core2 object, passes: $out"

cc1 -march=penryn "$t/loop.c" -o "$t/plain.o"
sed 's/void vmin/void vminpp/' "$t/loop.c" > "$t/loop.cpp"
cc1 -march=penryn "$t/loop.cpp" -o "$t/pp.o"
prefix nobc "$t/plain.o" "$t/pp.o"
if out="$(CORE2_ALLOWLIST=/dev/null sh "$A" "$t/nobc" 2>&1)"; then fail "an object with no bitcode to read falls back to the allowlist, and vmin is not listed: $out"; fi
case "$out" in *"libfix.rlib"*" vmin uses p"*"(allowlist)"*) : ;; *) fail "the fallback says which rule applied: $out" ;; esac
case "$out" in *"libfix.rlib(pp.o) vminpp(int*, int const*, int) uses p"*"(allowlist)"*) : ;; *) fail "a demangled name with spaces is printed whole: $out" ;; esac
printf 'vmin\nvminpp(int*, int const*, int)\n' > "$t/allow"
out="$(CORE2_ALLOWLIST="$t/allow" sh "$A" "$t/nobc" 2>&1)" || fail "an object with no readable bitcode passes when its function is listed: $out"

mkdir -p "$t/exe/bin"
printf 'void vmin(int *, const int *, int);\nint main(int c, char **v) { int a[64] = {c}, b[64] = {1}; (void)v; vmin(a, b, 64); return a[0]; }\n' > "$t/main.c"
fixture_cc -march=core2 -O2 -c "$t/main.c" -o "$t/main.o"
fixture_cc "$t/main.o" "$t/penryn.o" -o "$t/exe/bin/tool" || fail "could not link the executable fixture"
if out="$(CORE2_ALLOWLIST=/dev/null sh "$A" "$t/exe" 2>&1)"; then fail "an executable with SSE4.1 in an unlisted function fails: $out"; fi
case "$out" in *"core2: $t/exe/bin/tool vmin uses p"*) : ;; *) fail "the executable's offender names the file and the function: $out" ;; esac
out="$(CORE2_ALLOWLIST="$t/allow" sh "$A" "$t/exe" 2>&1)" || fail "a listed function may hold SSE4.1: $out"
case "$out" in "core2: 0 objects, 1 executables clean") : ;; *) fail "the clean executable run says what it checked: $out" ;; esac

mkdir -p "$t/none"
if out="$(sh "$A" "$t/none" 2>&1)"; then fail "a prefix with nothing to check is an error, not clean: $out"; fi
n="$(grep -n 'build/assert-core2.sh" "$S"' "$ROOT/tests/smoke-native.sh" | cut -d: -f1)"; a="$(grep -n '^audit "$S"' "$ROOT/tests/smoke-native.sh" | cut -d: -f1)"
[ -n "$n" ] && [ "$n" -gt "$a" ] || fail "smoke-native audits the native stage for core2 in its static half"
echo "PASS assert-core2"
