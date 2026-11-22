#!/bin/sh
# platform: host-agnostic
#   usage: smoke-native.sh
#          The static half audits fixture stages (a good one passes, each bad one fails), then the native
#          stage if one is built: the seven tools, every Mach-O thin x86_64 with minos 10.9 and sdk 10.9,
#          no /opt/ or work-tree path loaded, guard_prefix, _clock_gettime defined in cargo (Recaulk's,
#          since 10.9's libSystem has none), and build/assert-core2.sh: nothing a Core 2 Mac cannot run.
#          The executing half compiles and runs a program with the stage, on an x86_64 Mac only, decided
#          from uname -s and hw.optional.arm64.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/build/versions.sh"; . "$ROOT/build/lib-rust.sh"; . "$ROOT/tests/lib/clang22.sh"; macho_tools
S="$NATIVE_STAGE_ROOT$NATIVE_PREFIX"
t="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/smoke-native.XXXXXX")" && pwd)"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; exit 1; }

minos_sdk() {
  "$OTOOL" -l "$1" | awk '$1 == "cmd" { r = ($2 == "LC_VERSION_MIN_MACOSX" || $2 == "LC_BUILD_VERSION") }
    r && ($1 == "version" || $1 == "minos") { m = $2 } r && $1 == "sdk" { s = $2 } END { print m " " s }'
}
loads() {
  "$OTOOL" -L "$1" | tail -n +2 | awk '{ print $1 }'
  "$OTOOL" -l "$1" | awk '/LC_RPATH/ { r = 1 } r && / path / { print $2; r = 0 }'
}
audit() {
  for _t in rustc cargo rustdoc clippy-driver cargo-clippy rustfmt cargo-fmt; do
    [ -x "$1/bin/$_t" ] || { echo "lacks bin/$_t (spec decision 6; a stale pre-3A stage looks built without it)"; return 1; }
  done
  find "$1/bin" "$1/lib" -type f -perm -u+x | while IFS= read -r _f; do
    case "$(file "$_f")" in *Mach-O*executable*|*Mach-O*"dynamically linked shared library"*) echo "$_f" ;; esac
  done > "$t/list"
  [ -s "$t/list" ] || { echo "no Mach-O under $1 -- nothing audited"; return 1; }
  while IFS= read -r _f; do
    "$LIPO" -info "$_f" | grep -Eq 'architecture: x86_64 *$' || { echo "${_f#"$1"/} is not thin x86_64"; return 1; }
    _v="$(minos_sdk "$_f")"
    [ "$_v" = "10.9 10.9" ] || { echo "${_f#"$1"/} records minos and sdk '$_v', not '10.9 10.9'"; return 1; }
    _p="$(loads "$_f" | grep -E "^/opt/|^$WORK_ROOT/" | sed -n 1p)" || _p=""
    [ -z "$_p" ] || { echo "${_f#"$1"/} loads $_p"; return 1; }
  done < "$t/list"
  guard_prefix "$1" > "$t/guard.out" 2>&1 || { echo "guard_prefix refuses $1:"; cat "$t/guard.out"; return 1; }
  "$NM" --defined-only "$1/bin/cargo" | awk '$3 == "_clock_gettime" { f = 1 } END { exit !f }' \
    || { echo "bin/cargo does not define _clock_gettime: 10.9's libSystem has none, so Recaulk's was not linked"; return 1; }
}

printf 'int main(void) { return 0; }\n' > "$t/main.c"
printf 'int clock_gettime(int c, void *s) { (void)c; (void)s; return 0; }\nint main(void) { return 0; }\n' > "$t/cargo.c"
printf 'int f(void) { return 1; }\n' > "$t/f.c"
G="$t/good"; mkdir -p "$G/bin" "$G/lib"
fixture_cc -o "$G/bin/rustc.bin" "$t/main.c"
fixture_cc -o "$G/bin/cargo" "$t/cargo.c"
fixture_cc -dynamiclib -install_name @rpath/libf.dylib -o "$G/lib/libf.dylib" "$t/f.c"
printf '#!/bin/sh\nexec "$0.bin" "$@"\n' > "$G/bin/rustc"; chmod +x "$G/bin/rustc"
for b in rustdoc clippy-driver cargo-clippy rustfmt cargo-fmt; do cp "$G/bin/rustc.bin" "$G/bin/$b"; done
audit "$G" > "$t/out" || { cat "$t/out"; fail "a 10.9 x86_64 fixture stage must pass the static audit"; }
bad() {
  rm -rf "$t/bad"; cp -R "$G" "$t/bad"; "$@"
  if audit "$t/bad" > "$t/out"; then fail "the static audit passed a fixture stage it must refuse: $why"; fi
  grep -q "$want" "$t/out" || { cat "$t/out"; fail "the refusal must say $want ($why)"; }
}
why="minos 10.12"; want="records minos and sdk '10.12"
bad "$CLANGDIR/bin/clang" --no-default-config -fuse-ld=lld --ld-path="$CLANGDIR/bin/ld64.lld" \
  -target x86_64-apple-macos10.12 -isysroot "$S9" -o "$t/bad/bin/rustdoc" "$t/main.c"
why="an rpath into /opt/pkg"; want="loads /opt/pkg/lib"
bad fixture_cc -Wl,-rpath,/opt/pkg/lib -o "$t/bad/bin/rustfmt" "$t/main.c"
why="cargo without Recaulk's clock_gettime"; want="_clock_gettime"
bad fixture_cc -o "$t/bad/bin/cargo" "$t/main.c"
why="no cargo-fmt"; want="lacks bin/cargo-fmt"
bad rm "$t/bad/bin/cargo-fmt"

if [ ! -e "$S/bin/rustc" ]; then echo "OK smoke-native (fixtures; no native stage built)"; exit 0; fi
audit "$S" > "$t/out" || { cat "$t/out"; fail "the native stage at $S"; }
sh "$ROOT/build/assert-core2.sh" "$S" > "$t/core2" 2>&1 || { cat "$t/core2"; fail "the native stage holds code a Core 2 Mac cannot run (patch 0003)"; }
cat "$t/core2"
echo "(static audit of the native stage passed)"

arm="$(sysctl -n hw.optional.arm64 2>/dev/null)" || arm=0
if [ "$(uname -s)" != Darwin ] || [ "$arm" = 1 ]; then
  echo "OK smoke-native (static; the executing half needs an x86_64 Mac, and this is $(uname -s) $(uname -m))"
  exit 0
fi
# spec: INGREDIENTS.md "The default linker" -- the stage has no clang22 beside it, so the link names
#       the one the build prepared (its SDK and Recaulk), which matches only a current stage
stage_is_current "$WORK_ROOT/work-native/staged.stamp" native \
  || { echo "the native stage is stale (build-native.sh again) -- skipping the on-box link"; exit 77; }
c22="$WORK_ROOT/work-native/clang22-$(tr -d ' \t\n' < "$CLANG_PIN_FILE")/bin/clang++"
[ -x "$c22" ] || fail "the build's clang22 is gone: $c22"
sed -n '/^use std::collections/,/^}/p' "$HERE/smoke-target-exec.sh" > "$t/smoke.rs"
"$S/bin/rustc" -C linker="$c22" "$t/smoke.rs" -o "$t/smoke"
out="$("$t/smoke")"
[ "$out" = 'smoke Some(109) 42' ] || fail "native output: $out"
echo "(compiled and ran on an x86_64 Mac)"
echo "OK smoke-native"
