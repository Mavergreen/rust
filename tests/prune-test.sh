#!/bin/sh
# platform: macOS-only -- builds dylibs with /usr/bin/clang and reads them with nm
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"; export TARGET_TRIPLE MACOS_MIN REPO_ROOT
. "$ROOT/build/lib-rust.sh"
t="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/prune.XXXXXX")" && pwd)"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; exit 1; }
mkdir -p "$t/p/lib" "$t/p/bin"
printf 'int __rustc_proc_macro_decls_0123abcd__ = 1;\n' > "$t/pm.c"
printf 'int rustc_driver_main(void) { return 0; }\n' > "$t/drv.c"
/usr/bin/clang -dynamiclib -o "$t/p/lib/libserde_derive-0123456789abcdef.dylib" "$t/pm.c"
/usr/bin/clang -dynamiclib -o "$t/p/lib/librustc_driver-0123456789abcdef.dylib" "$t/drv.c"
ln -s librustc_driver-0123456789abcdef.dylib "$t/p/lib/librustc_driver.dylib"
prune_proc_macro_dylibs "$t/p"
[ ! -e "$t/p/lib/libserde_derive-0123456789abcdef.dylib" ] \
  || fail "a proc-macro dylib (exports __rustc_proc_macro_decls_*__) must be pruned: a cross-hosted x.py install leaves 17 that nothing links"
[ -f "$t/p/lib/librustc_driver-0123456789abcdef.dylib" ] || fail "an ordinary dylib must be kept"
[ -h "$t/p/lib/librustc_driver.dylib" ] || fail "symlinks must be left alone"
echo "OK prune-test"
