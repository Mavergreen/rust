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
int plain(int a) { return a + 1; }
C
cc1() { "$CLANGDIR/bin/clang" --no-default-config --target=x86_64-apple-macos10.9 -O2 -c "$@"; }
prefix() {
  d="$t/$1/lib/rustlib/x86_64-apple-darwin/lib"; mkdir -p "$d" "$t/$1/bin"; shift
  "$CLANGDIR/bin/llvm-ar" rc "$d/libfix.rlib" "$@"
}
cc1 -march=core2 -fembed-bitcode "$t/loop.c" -o "$t/core2.o"
cc1 -march=penryn -fembed-bitcode "$t/loop.c" -o "$t/penryn.o"
cc1 -march=core2 -fembed-bitcode "$t/opt.c" -o "$t/opt.o"
"$CLANGDIR/bin/llvm-objdump" -d "$t/penryn.o" | grep -q pminsd || fail "the penryn fixture must hold SSE4.1, or this test proves nothing"

prefix good "$t/core2.o"
out="$(sh "$A" "$t/good" 2>&1)" || fail "a core2 rlib passes: $out"
case "$out" in *"core2: 1 objects, 0 executables clean") : ;; *) fail "a clean run says what it checked: $out" ;; esac

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
case "$out" in *"core2: 0 objects, 1 executables clean") : ;; *) fail "the clean executable run says what it checked: $out" ;; esac

mkdir -p "$t/junk/bin"; printf '\317\372\355\376garbage' > "$t/junk/bin/tool"
if out="$(CORE2_ALLOWLIST=/dev/null sh "$A" "$t/junk" 2>&1)"; then fail "a Mach-O the disassembler cannot read is an error, not clean: $out"; fi

prefix owndis "$t/penryn.o"
d="$t/owndis/lib/rustlib/x86_64-apple-darwin/bin"; mkdir -p "$d"
printf '#!/bin/sh\n: > "%s"\nexec "%s" "$@"\n' "$t/own-used" "$CLANGDIR/bin/llvm-dis" > "$d/llvm-dis"; chmod +x "$d/llvm-dis"
if out="$(env -u LLVM_DIS sh "$A" "$t/owndis" 2>&1)"; then fail "the penryn object still fails with the prefix's own llvm-dis: $out"; fi
[ -e "$t/own-used" ] || fail "the prefix's own llvm-dis, which matches its rustc's LLVM, reads its bitcode: $out"

cat > "$t/hashed.c" <<'C'
void hv(int *a, const int *b, int n) __asm__("__ZN4core3fmt5write17h0123456789abcdefE.llvm.4242");
void hv(int *a, const int *b, int n) { for (int i = 0; i < n; i++) { int x = a[i] < b[i] ? a[i] : b[i]; a[i] = x * b[i]; } }
C
cc1 -march=penryn "$t/hashed.c" -o "$t/hashed.o"
prefix hashed "$t/hashed.o"
if out="$(CORE2_ALLOWLIST=/dev/null sh "$A" "$t/hashed" 2>&1)"; then fail "the hashed fixture fails unlisted: $out"; fi
case "$out" in *") core::fmt::write uses p"*) : ;; *) fail "the name drops the build-specific .llvm.N suffix and ::h hash: $out" ;; esac
printf 'core::fmt::write\n' > "$t/allow2"
out="$(CORE2_ALLOWLIST="$t/allow2" sh "$A" "$t/hashed" 2>&1)" || fail "an allowlist entry survives a rebuild's new .llvm.N and hash: $out"

cc1 -march=core2 -msse4.1 -fembed-bitcode "$t/loop.c" -o "$t/global.o"
"$CLANGDIR/bin/llvm-objdump" -d "$t/global.o" | grep -q pminsd || fail "the global-feature fixture must hold SSE4.1"
prefix global "$t/global.o"
if out="$(CORE2_ALLOWLIST=/dev/null sh "$A" "$t/global" 2>&1)"; then fail "a feature every function in an object enables was set globally, not by a function's own attribute: $out"; fi
case "$out" in *" vmin uses p"*"(bitcode)"*) : ;; *) fail "the global-feature offender is named under the bitcode rule: $out" ;; esac

cat > "$t/ins.s" <<'S'
.text
.macro one name, insn:vararg
.globl \name
\name:
 \insn
 ret
.endm
one _t_tzcnt, tzcntl %eax, %ecx
one _t_rdtscp, rdtscp
one _t_xgetbv, xgetbv
one _t_xsetbv, xsetbv
one _t_xsave, xsave (%rax)
one _t_xrstor, xrstor (%rax)
one _t_xbegin, xbegin 1f
1:
one _t_xend, xend
one _t_xabort, xabort $1
one _t_xtest, xtest
one _t_rdfsbase, rdfsbase %rax
one _t_wrgsbase, wrgsbase %rax
one _t_clflushopt, clflushopt (%rax)
one _t_clwb, clwb (%rax)
one _t_rdpid, rdpid %rax
one _t_gf2p8, gf2p8affineqb $0, %xmm1, %xmm0
one _t_pextrwmem, pextrw $1, %xmm0, (%rdi)
one _t_extrq, extrq $1, $2, %xmm0
one _t_insertq, insertq $1, $2, %xmm1, %xmm0
one _t_movntss, movntss %xmm0, (%rax)
.globl _t_ok
_t_ok:
 pextrw $1, %xmm0, %eax
 pminub %xmm1, %xmm0
 rep stosq
 lock xaddl %eax, (%rdi)
 ret
S
"$CLANGDIR/bin/clang" --no-default-config --target=x86_64-apple-macos10.9 -c "$t/ins.s" -o "$t/ins.o"
prefix ins "$t/ins.o"
out="$(CORE2_ALLOWLIST=/dev/null sh "$A" "$t/ins" 2>&1)" || :
for f in tzcnt rdtscp xgetbv xsetbv xsave xrstor xbegin xend xabort xtest rdfsbase wrgsbase clflushopt clwb rdpid gf2p8 pextrwmem extrq insertq movntss; do
  case "$out" in *" t_$f uses "*) : ;; *) fail "t_$f holds an instruction a Core 2 lacks: $out" ;; esac
done
case "$out" in *" t_ok uses "*) fail "SSE2 pminub, the register form of pextrw, rep and lock are all core2: $out" ;; esac

mkdir -p "$t/fake"
printf '#!/bin/sh\nfor a do f="$a"; done\nprintf "%%s:\\tfile format mach-o 64-bit x86-64\\n\\n0000000000000000 <_p>:\\n       0:      \\trex64\\tpminsd\\t%%%%xmm1, %%%%xmm0\\n       5:      \\tdata16\\tptest\\t%%%%xmm1, %%%%xmm0\\n" "$f"\n' > "$t/fake/llvm-objdump"; chmod +x "$t/fake/llvm-objdump"
prefix pfx "$t/core2.o"
out="$(LLVM_OBJDUMP="$t/fake/llvm-objdump" CORE2_ALLOWLIST=/dev/null sh "$A" "$t/pfx" 2>&1)" || :
case "$out" in *" p uses pminsd"*) : ;; *) fail "a prefix token (rex64, data16) on the line does not hide the instruction after it: $out" ;; esac

cat > "$t/st.c" <<'C'
__attribute__((noinline)) static void hidden(int *a, const int *b, int n) { for (int i = 0; i < n; i++) { int x = a[i] < b[i] ? a[i] : b[i]; a[i] = x * b[i]; } }
void listedf(int *a) { a[0] = 1; }
int main(int c, char **v) { int a[64] = {c}, b[64] = {1}; (void)v; listedf(a); hidden(a, b, 64); return a[0]; }
C
mkdir -p "$t/strip/bin"
fixture_cc -O2 -march=penryn "$t/st.c" -o "$t/st"
"$CLANGDIR/bin/llvm-strip" -x "$t/st" -o "$t/strip/bin/tool"
printf 'main\nlistedf\n' > "$t/allow3"
if out="$(CORE2_ALLOWLIST="$t/allow3" sh "$A" "$t/strip" 2>&1)"; then fail "a stripped function's SSE4.1 is not credited to the listed symbol before it: $out"; fi
case "$out" in *"unnamed-function@0x"*" uses pminsd"*) : ;; *) fail "the stripped function is reported as unnamed, by its start: $out" ;; esac

mkdir -p "$t/none"
if out="$(sh "$A" "$t/none" 2>&1)"; then fail "a prefix with nothing to check is an error, not clean: $out"; fi
n="$(grep -n 'build/assert-core2.sh" "$S"' "$ROOT/tests/smoke-native.sh" | cut -d: -f1)"; a="$(grep -n '^audit "$S"' "$ROOT/tests/smoke-native.sh" | cut -d: -f1)"
[ -n "$n" ] && [ "$n" -gt "$a" ] || fail "smoke-native audits the native stage for core2 in its static half"
echo "PASS assert-core2"
