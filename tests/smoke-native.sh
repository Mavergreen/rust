#!/bin/sh
# platform: macOS-only -- macho_tools' llvm-lipo, and assert_binary_compatible.sh's otool/nm through it
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/build/versions.sh"
S="$NATIVE_STAGE_ROOT$NATIVE_PREFIX"
[ -x "$S/bin/rustc" ] || { echo "not built -- skipping"; exit 77; }
fail() { echo "FAIL $1"; exit 1; }
for t in rustc cargo rustdoc clippy-driver cargo-clippy rustfmt cargo-fmt; do
  [ -x "$S/bin/$t" ] || fail "native stage lacks bin/$t (spec decision 6; a stale pre-3A stage looks built without it)"
done
list="$(mktemp "${TMPDIR:-/tmp}/smoke-native.XXXXXX")"; trap 'rm -f "$list"' EXIT
find "$S/bin" "$S/lib" -type f -perm -u+x | while IFS= read -r f; do
  case "$(file "$f")" in *Mach-O*executable*|*Mach-O*"dynamically linked shared library"*) echo "$f" ;; esac
done > "$list"
[ -s "$list" ] || fail "no Mach-O found under $S -- nothing audited"
. "$ROOT/build/lib-rust.sh"; macho_tools
while IFS= read -r f; do
  "$LIPO" -info "$f" | grep -Eq 'architecture: x86_64 *$' || fail "$f is not thin x86_64"
done < "$list"
guard_prefix "$S"

if [ "$(sh "$SHIPYARD_SCRIPTS/mavericks_mode.sh")" = native ]; then
  # spec: INGREDIENTS.md "The default linker" -- the stage has no clang22 beside it, so the link names
  #       the one the build prepared (its SDK and Recaulk), which matches only a current stage
  stage_is_current "$WORK_ROOT/work-native/staged.stamp" native \
    || { echo "the native stage is stale (build-native.sh again) -- skipping the on-box link"; exit 77; }
  c22="$WORK_ROOT/work-native/clang-native-$(tr -d ' \t\n' < "$CLANG_PIN_FILE")/bin/clang++"
  [ -x "$c22" ] || fail "the build's clang22 is gone: $c22"
  t="$(mktemp -d "${TMPDIR:-/tmp}/mavnat.XXXXXX")"; trap 'rm -rf "$t" "$list"' EXIT
  sed -n '/^use std::collections/,/^}/p' "$HERE/smoke-target.sh" > "$t/smoke.rs"
  "$S/bin/rustc" -C linker="$c22" "$t/smoke.rs" -o "$t/smoke"
  out="$("$t/smoke")"
  [ "$out" = 'smoke Some(109) 42' ] || fail "native output: $out"
  echo "(compiled and ran on real 10.9)"
fi
echo "OK smoke-native"
