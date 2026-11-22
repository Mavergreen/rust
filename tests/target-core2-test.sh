#!/bin/sh
# platform: host-agnostic
#   usage: target-core2-test.sh [RUSTC]
#          rustc's x86_64-apple-darwin defaults to deployment target 10.9 and CPU core2 (patch 0003):
#          what it reports and what it compiles. RUSTC is the argument, else the Linux stage's rustc on
#          Linux, else the native stage's on an x86_64 Mac; with none, it checks nothing. It links nothing.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/build/versions.sh"; . "$ROOT/build/lib-rust.sh"
fail() { echo "FAIL $1"; exit 1; }
R="${1:-}"
if [ -z "$R" ]; then
  if [ "$(uname -s)" = Linux ]; then c="$LINUX_STAGE_ROOT$LINUX_PREFIX/bin/rustc"
  elif [ "$(uname -m)" = x86_64 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != 1 ]; then c="$NATIVE_STAGE_ROOT$NATIVE_PREFIX/bin/rustc"
  else c=""; fi
  # platform: release.yml's build jobs keep no runnable stage for this; linux-smoke runs it on the tarball
  [ -n "$c" ] && [ -x "$c" ] || { echo "OK target-core2 (no staged rustc runs on this host)"; exit 0; }
  R="$c"
fi
. "$ROOT/tests/lib/clang22.sh"; macho_tools
OBJDUMP="$(dirname "$OTOOL")/llvm-objdump"
t="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/target-core2.XXXXXX")" && pwd)"; trap 'rm -rf "$t"' EXIT

out="$(env -u MACOSX_DEPLOYMENT_TARGET "$R" --print deployment-target --target x86_64-apple-darwin)"
[ "$out" = "MACOSX_DEPLOYMENT_TARGET=10.9" ] || fail "rustc's default deployment target for x86_64 Macs is 10.9: $out"
out="$(MACOSX_DEPLOYMENT_TARGET=10.12 "$R" --print deployment-target --target x86_64-apple-darwin)"
[ "$out" = "MACOSX_DEPLOYMENT_TARGET=10.12" ] || fail "MACOSX_DEPLOYMENT_TARGET still overrides the default: $out"
cfg="$("$R" --print cfg --target x86_64-apple-darwin)"
for f in sse4.1 sse4.2 popcnt; do
  case "$cfg" in *"target_feature=\"$f\""*) fail "the default CPU is core2, which lacks $f: --print cfg reports it" ;; esac
done
case "$cfg" in *'target_feature="ssse3"'*) : ;; *) fail "core2 has ssse3, and --print cfg should say so: $cfg" ;; esac

printf '%s\n' 'pub fn m(a: &mut [i32], b: &[i32]) { for (x, y) in a.iter_mut().zip(b) { *x = (*x).min(*y).wrapping_mul(*y); } }' > "$t/m.rs"
# platform: --no-default-config makes rust's wrapper pass through, so no clang22 is needed to emit an object
env -u MACOSX_DEPLOYMENT_TARGET "$R" --target x86_64-apple-darwin -O --crate-type=lib --emit=obj -C link-arg=--no-default-config -o "$t/core2.o" "$t/m.rs"
env -u MACOSX_DEPLOYMENT_TARGET "$R" --target x86_64-apple-darwin -O --crate-type=lib --emit=obj -C link-arg=--no-default-config -C target-cpu=penryn -o "$t/penryn.o" "$t/m.rs"
d="$("$OBJDUMP" -d "$t/core2.o")"
case "$d" in *pminsd*|*pmulld*) fail "with no flags rustc emits SSE4.1 (pminsd/pmulld), which a Core 2 Mac lacks" ;; esac
case "$("$OBJDUMP" -d "$t/penryn.o")" in *pminsd*) : ;; *) fail "-C target-cpu=penryn still gets SSE4.1: the default is not a ceiling (and without this the test sees nothing)" ;; esac
m="$("$OTOOL" -l "$t/core2.o" | awk '$1 == "cmd" { r = ($2 == "LC_VERSION_MIN_MACOSX" || $2 == "LC_BUILD_VERSION") }
  r && ($1 == "version" || $1 == "minos") { print $2; exit }')"
[ "$m" = 10.9 ] || fail "an object compiled with no flags records minos 10.9: $m"
echo "PASS target-core2"
