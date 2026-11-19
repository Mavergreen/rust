#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
t="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/macho-tools.XXXXXX")" && pwd)"; trap 'rm -rf "$t"' EXIT
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"; WORK_ROOT="$t/none"
export TARGET_TRIPLE MACOS_MIN REPO_ROOT WORK_ROOT
. "$ROOT/build/lib-rust.sh"
fail() { echo "FAIL $1"; exit 1; }
mkdir -p "$t/c/bin" "$t/bare/bin" "$t/linux" "$t/darwin"
for b in clang llvm-lipo llvm-otool llvm-nm llvm-strings llvm-install-name-tool; do
  printf '#!/bin/sh\n' > "$t/c/bin/$b"; chmod +x "$t/c/bin/$b"
done
printf '#!/bin/sh\ncase "$1" in -m) echo x86_64 ;; *) echo Linux ;; esac\n' > "$t/linux/uname"
printf '#!/bin/sh\ncase "$1" in -m) echo x86_64 ;; *) echo Darwin ;; esac\n' > "$t/darwin/uname"
chmod +x "$t/linux/uname" "$t/darwin/uname"
clean() { unset LIPO OTOOL NM STRINGS INSTALL_NAME_TOOL MACHO_CC CLANGDIR CLANG_PIN_FILE; }
got() { printf '%s %s %s %s %s %s' "$LIPO" "$OTOOL" "$NM" "$STRINGS" "$INSTALL_NAME_TOOL" "$MACHO_CC"; }
want="$t/c/bin/llvm-lipo $t/c/bin/llvm-otool $t/c/bin/llvm-nm $t/c/bin/llvm-strings $t/c/bin/llvm-install-name-tool $t/c/bin/clang"

( clean; PATH="$t/linux:$PATH"; CLANGDIR="$t/c"; macho_tools
  [ "$(got)" = "$want" ] || { echo "got: $(got)"; exit 1; }
  env | grep -q "^MACHO_CC=$t/c/bin/clang\$" ) \
  || fail "on Linux macho_tools exports LIPO OTOOL NM STRINGS INSTALL_NAME_TOOL MACHO_CC from \$CLANGDIR/bin, SDK or not"
if ( clean; PATH="$t/linux:$PATH"; macho_tools ) 2> "$t/err"; then
  fail "on Linux macho_tools must fail when CLANGDIR is unset: Linux has no Mach-O tools of its own"
fi
grep -q CLANGDIR "$t/err" || fail "the failure must name CLANGDIR"
if ( clean; PATH="$t/linux:$PATH"; CLANGDIR="$t/bare"; macho_tools ) 2>/dev/null; then
  fail "on Linux macho_tools must fail when \$CLANGDIR/bin has no llvm-otool, never fall back to the names a Mac has"
fi

( clean; PATH="$t/darwin:$PATH"; CLANGDIR="$t/bare"; macho_tools
  if [ "$LIPO" = /usr/local/mavergreen/clang22/bin/llvm-lipo ]; then [ "$OTOOL" = /usr/local/mavergreen/clang22/bin/llvm-otool ]
  else [ "$LIPO|$OTOOL|$NM|$STRINGS|$INSTALL_NAME_TOOL|$MACHO_CC" = "lipo|otool|nm|strings|install_name_tool|/usr/bin/clang" ]; fi ) \
  || fail "on a Mac macho_tools keeps its search list and its fallbacks"
( clean; PATH="$t/darwin:$PATH"; CLANGDIR="$t/c"; macho_tools
  [ "$LIPO $OTOOL $NM $STRINGS $INSTALL_NAME_TOOL" = "${want% *}" ] ) \
  || fail "on a Mac macho_tools still takes \$CLANGDIR/bin first"
echo "OK macho-tools-test"
