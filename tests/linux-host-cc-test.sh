#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
t="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/linux-host-cc.XXXXXX")" && pwd)"; trap 'rm -rf "$t"' EXIT
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"; WORK="$t/work"
CLANG_PIN_DIR="$ROOT/components/clang22"; SHIPYARD_SCRIPTS="$t/sy"
export TARGET_TRIPLE MACOS_MIN REPO_ROOT WORK CLANG_PIN_DIR SHIPYARD_SCRIPTS
. "$ROOT/build/lib-rust.sh"
fail() { echo "FAIL $1"; exit 1; }
command -v linux_host_compilers >/dev/null || fail "lib-rust.sh has no linux_host_compilers"

mkdir -p "$t/sy" "$t/c/bin" "$t/lcxx/lib" "$t/lcxx/include/c++/v1" "$t/linux" "$t/darwin"
cat > "$t/sy/fetch_host_libcxx.sh" <<EOF
printf '%s\n' "\$@" > "$t/fetch.args"
[ ! -f "$t/fetch.fails" ] || exit 1
echo "$t/lcxx"
EOF
for c in clang clang++; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/%s.args"\nprintf "%%s" "${SDKROOT-unset}" > "%s/%s.sdkroot"\n' "$t" "$c" "$t" "$c" \
    > "$t/c/bin/$c"; chmod +x "$t/c/bin/$c"
done
: > "$t/lcxx/lib/libc++.a"; : > "$t/lcxx/lib/libc++abi.a"; : > "$t/lcxx/include/c++/v1/__config_site"
printf '#!/bin/sh\ncase "$1" in -m) echo x86_64 ;; *) echo Linux ;; esac\n' > "$t/linux/uname"
printf '#!/bin/sh\ncase "$1" in -m) echo arm64 ;; *) echo Darwin ;; esac\n' > "$t/darwin/uname"
chmod +x "$t/linux/uname" "$t/darwin/uname"
args() { tr '\n' ' ' < "$t/$1.args" | sed 's/ $//'; }

( PATH="$t/darwin:$PATH"; unset LINUX_HOST_CC LINUX_HOST_CXX
  linux_host_compilers "$t/c"
  [ -z "${LINUX_HOST_CC:-}${LINUX_HOST_CXX:-}" ] && [ ! -e "$t/fetch.args" ] ) \
  || fail "on a Mac linux_host_compilers must do nothing: only a Linux build triple compiles for Linux"

PATH="$t/linux:$PATH" linux_host_compilers "$t/c" || fail "linux_host_compilers failed on Linux"
[ "$(args fetch)" = "$CLANG_PIN_DIR $t/c" ] \
  || fail "the host libc++ comes from shipyard's fetch_host_libcxx.sh PIN_DIR CLANG22_PREFIX (got '$(args fetch)')"
[ "$LINUX_HOST_CC" = "$WORK/linux-host/cc" ] && [ "$LINUX_HOST_CXX" = "$WORK/linux-host/c++" ] \
  || fail "LINUX_HOST_CC and LINUX_HOST_CXX are \$WORK/linux-host/cc and c++ (got '$LINUX_HOST_CC' '$LINUX_HOST_CXX')"
[ -x "$LINUX_HOST_CC" ] && [ -x "$LINUX_HOST_CXX" ] || fail "the wrappers must be executable"
( env | grep -q "^LINUX_HOST_CC=$LINUX_HOST_CC\$" && env | grep -q "^LINUX_HOST_CXX=$LINUX_HOST_CXX\$" ) \
  || fail "LINUX_HOST_CC and LINUX_HOST_CXX must be exported"

d4='--no-default-config --target=x86_64-unknown-linux-gnu -march=core2'
ld='-fuse-ld=lld -rtlib=libgcc --unwindlib=libgcc'
inc="-nostdinc++ -isystem $t/lcxx/include/c++/v1"
"$LINUX_HOST_CC" -c x.c -o x.o
[ "$(args clang)" = "$d4 -c x.c -o x.o" ] \
  || fail "cc compiling: D4's flags and nothing a compile leaves unused (got '$(args clang)')"
"$LINUX_HOST_CC" x.o -o x
[ "$(args clang)" = "$d4 $ld x.o -o x" ] || fail "cc linking: lld, and the libgcc runtime libc++abi was built for (got '$(args clang)')"
for m in -E -S -M -MM -fsyntax-only; do
  "$LINUX_HOST_CC" "$m" x.c
  [ "$(args clang)" = "$d4 $m x.c" ] || fail "cc $m links nothing, so it gets no link flags (got '$(args clang)')"
done
"$LINUX_HOST_CXX" -c y.cpp -o y.o
[ "$(args clang++)" = "$d4 $inc -c y.cpp -o y.o" ] \
  || fail "c++ compiling: D4's flags and the host libc++'s headers only (got '$(args clang++)')"
"$LINUX_HOST_CXX" y.o -o y
[ "$(args clang++)" = "$d4 $inc $ld -nostdlib++ -L$t/lcxx/lib y.o -o y $t/lcxx/lib/libc++.a $t/lcxx/lib/libc++abi.a -lpthread" ] \
  || fail "c++ linking: the host libc++ and libc++abi, static, after the objects, and -lc++ (rustc_llvm's, with llvm.use-libcxx) finds the same libc++.a (got '$(args clang++)')"
for m in --version -dumpversion -dumpmachine -print-file-name=libstdc++.a -print-search-dirs; do
  "$LINUX_HOST_CXX" "$m"
  [ "$(args clang++)" = "$d4 $inc $m" ] || fail "c++ $m links nothing, so it gets no link flags or libraries (got '$(args clang++)')"
done
SDKROOT=/sdk109 "$LINUX_HOST_CC" -c x.c -o x.o
SDKROOT=/sdk109 "$LINUX_HOST_CXX" y.o -o y
[ "$(cat "$t/clang.sdkroot")" = unset ] && [ "$(cat "$t/clang++.sdkroot")" = unset ] \
  || fail "a Linux build exports SDKROOT for rustc's Apple links, and the build triple's cc and c++ must not see the 10.9 SDK (got '$(cat "$t/clang.sdkroot")' '$(cat "$t/clang++.sdkroot")')"

: > "$t/fetch.fails"
if ( PATH="$t/linux:$PATH"; linux_host_compilers "$t/c" ) 2>/dev/null; then
  fail "a failed fetch_host_libcxx.sh must fail linux_host_compilers"
fi
rm -f "$t/fetch.fails" "$t/lcxx/lib/libc++abi.a"
if ( PATH="$t/linux:$PATH"; linux_host_compilers "$t/c" ) 2> "$t/err"; then
  fail "a host libc++ prefix without lib/libc++abi.a must fail linux_host_compilers"
fi
grep -q 'libc++abi.a' "$t/err" || fail "the failure must name what the prefix lacks"
echo "OK linux-host-cc-test"
