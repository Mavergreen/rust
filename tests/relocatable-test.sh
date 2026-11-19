#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"; export TARGET_TRIPLE MACOS_MIN REPO_ROOT
. "$ROOT/build/versions.sh"; . "$ROOT/build/lib-rust.sh"; . "$ROOT/tests/lib/clang22.sh"; macho_tools
t="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/relocatable.XXXXXX")" && pwd)"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; cat "$t/out" 2>/dev/null; exit 1; }
rpaths() { "$OTOOL" -l "$1" | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}' | tr '\n' ' ' | sed 's/ $//'; }

WORK="$t/work"; export WORK
printf 'int f(void) { return 1; }\n' > "$t/f.c"
printf 'int main(void) { return 0; }\n' > "$t/m.c"
mkdir -p "$t/p/bin" "$t/p/lib/rustlib/$TARGET_TRIPLE/lib" "$t/q/bin" "$t/q/lib"
fixture_cc -dynamiclib -install_name @rpath/libf.dylib -Wl,-rpath,"$WORK/clang22-x/lib" -o "$t/p/lib/libf.dylib" "$t/f.c"
fixture_cc -dynamiclib -install_name @rpath/libstd.dylib -Wl,-rpath,"$WORK/build/lib" \
  -o "$t/p/lib/rustlib/$TARGET_TRIPLE/lib/libstd-0123456789abcdef.dylib" "$t/f.c"
fixture_cc -Wl,-rpath,"$WORK/build/lib" -o "$t/p/bin/tool" "$t/m.c"
fixture_cc -Wl,-rpath,/opt/pkg/lib -o "$t/q/bin/tool" "$t/m.c"
cp "$t/p/lib/libf.dylib" "$t/q/lib/"

relocate_prefix "$t/p" "$t/clang"
[ "$(rpaths "$t/p/lib/libf.dylib")" = @loader_path ] \
  || fail "an rpath into \$WORK must become @loader_path in lib/ (got '$(rpaths "$t/p/lib/libf.dylib")')"
[ "$(rpaths "$t/p/lib/rustlib/$TARGET_TRIPLE/lib/libstd-0123456789abcdef.dylib")" = @loader_path/../../.. ] \
  || fail "an rpath into \$WORK must become @loader_path/../../.. in lib/rustlib/<triple>/lib"
[ "$(rpaths "$t/p/bin/tool")" = @loader_path/../lib ] \
  || fail "an rpath into \$WORK must become @loader_path/../lib in bin/ (got '$(rpaths "$t/p/bin/tool")')"
sh "$ROOT/build/verify-relocatable.sh" "$t/p" > "$t/out" 2>&1 || fail "a prefix relocate_prefix rewrote must verify"

relocate_prefix "$t/q" "$t/clang"
case " $(rpaths "$t/q/bin/tool") " in *" /opt/pkg/lib "*) : ;; *) fail "relocate_prefix rewrites only rpaths into \$WORK or clang22" ;; esac
rc=0; sh "$ROOT/build/verify-relocatable.sh" "$t/q" > "$t/out" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "an absolute rpath left in a prefix must make verify-relocatable.sh exit 1 (got $rc)"
grep -q '/opt/pkg/lib' "$t/out" || fail "verify-relocatable.sh must name the absolute rpath"
unset WORK

audited=0
for pair in "cross:$CROSS_STAGE_ROOT$CROSS_PREFIX" "native:$NATIVE_STAGE_ROOT$NATIVE_PREFIX"; do
  variant="${pair%%:*}"; stage="${pair#*:}"
  [ -x "$stage/bin/rustc" ] || continue
  echo "== relocatable-test: $variant ($stage) =="
  sh "$ROOT/build/verify-relocatable.sh" "$stage"
  ! ls "$stage"/lib/libc++* "$stage"/lib/libunwind* >/dev/null 2>&1 \
    || { echo "FAIL $variant: bundles libc++/libunwind that nothing links (rustc and LLVM use /usr/lib/libc++.1.dylib)"; exit 1; }
  audited=$((audited + 1))
done
echo "OK relocatable-test (fixtures, and $audited staged variant(s))"
