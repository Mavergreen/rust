#!/bin/sh
# platform: host-agnostic
#   usage: smoke-target.sh
#          The static half of the cross stage's smoke. It audits fixture stages (a good one passes, each
#          bad one fails) where clang22 has AArch64, then the cross stage if one is built: the seven
#          tools, bin/rustc.bin thin arm64 with minos 11.0 and sdk 11.3, the bundled
#          lib/rustlib/x86_64-apple-darwin/lib/librecaulk.a thin x86_64, and guard_prefix.
#          smoke-target-exec.sh is the executing half.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/build/versions.sh"; . "$ROOT/build/lib-rust.sh"; . "$ROOT/tests/lib/clang22.sh"; macho_tools
S="$CROSS_STAGE_ROOT$CROSS_PREFIX"
t="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/smoke-target.XXXXXX")" && pwd)"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; exit 1; }

minos_sdk() {
  "$OTOOL" -l "$1" | awk '$1 == "cmd" { v = ($2 == "LC_VERSION_MIN_MACOSX"); b = ($2 == "LC_BUILD_VERSION") }
    (v && $1 == "version") || (b && $1 == "minos") { m = $2 } (v || b) && $1 == "sdk" { s = $2 } END { print m " " s }'
}
audit() {
  for _t in rustc cargo rustdoc clippy-driver cargo-clippy rustfmt cargo-fmt; do
    [ -x "$1/bin/$_t" ] || { echo "lacks bin/$_t"; return 1; }
  done
  "$LIPO" -info "$1/bin/rustc.bin" | grep -Eq 'architecture: arm64 *$' || { echo "bin/rustc.bin is not thin arm64"; return 1; }
  _v="$(minos_sdk "$1/bin/rustc.bin")"
  [ "$_v" = "11.0 11.3" ] || { echo "bin/rustc.bin records minos and sdk '$_v', not '11.0 11.3'"; return 1; }
  _a="$1/lib/rustlib/x86_64-apple-darwin/lib/librecaulk.a"
  [ -f "$_a" ] || { echo "lacks the bundled librecaulk.a"; return 1; }
  "$LIPO" -info "$_a" | grep -Eq 'architecture: x86_64 *$' || { echo "the bundled librecaulk.a is not thin x86_64"; return 1; }
  guard_prefix "$1" > "$t/guard.out" 2>&1 || { echo "guard_prefix refuses $1:"; cat "$t/guard.out"; return 1; }
}

if "$CLANGDIR/bin/clang" --print-targets | grep -q aarch64; then
  S113="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch arm64)"
  write_pinned_cc "$t/cc-arm64" "$S113" "$CLANGDIR"
  printf 'int main(void) { return 0; }\n' > "$t/main.c"
  printf 'int f(void) { return 1; }\n' > "$t/f.c"
  G="$t/good"; mkdir -p "$G/bin" "$G/lib/rustlib/x86_64-apple-darwin/lib"
  "$t/cc-arm64" -Wl,-headerpad_max_install_names -o "$G/bin/rustc.bin" "$t/main.c"
  printf '#!/bin/sh\nexec "$0.bin" "$@"\n' > "$G/bin/rustc"; chmod +x "$G/bin/rustc"
  for b in cargo rustdoc clippy-driver cargo-clippy rustfmt cargo-fmt; do cp "$G/bin/rustc.bin" "$G/bin/$b"; done
  fixture_cc -c -o "$t/f.o" "$t/f.c"
  "$CLANGDIR/bin/llvm-ar" rcs "$G/lib/rustlib/x86_64-apple-darwin/lib/librecaulk.a" "$t/f.o"
  audit "$G" > "$t/out" || { cat "$t/out"; fail "an arm64 11.0 fixture stage with an x86_64 librecaulk.a must pass the static audit"; }
  bad() {
    rm -rf "$t/bad"; cp -R "$G" "$t/bad"; "$@"
    if audit "$t/bad" > "$t/out"; then fail "the static audit passed a fixture stage it must refuse: $why"; fi
    grep -q "$want" "$t/out" || { cat "$t/out"; fail "the refusal must say $want ($why)"; }
  }
  why="an x86_64 rustc"; want="bin/rustc.bin is not thin arm64"
  bad fixture_cc -o "$t/bad/bin/rustc.bin" "$t/main.c"
  why="minos 12.0"; want="records minos and sdk '12.0 11.3'"
  bad "$CLANGDIR/bin/clang" --no-default-config --target=arm64-apple-macos12.0 -fuse-ld=lld -isysroot "$S113" \
    -o "$t/bad/bin/rustc.bin" "$t/main.c"
  "$t/cc-arm64" -c -o "$t/f-arm64.o" "$t/f.c"
  arm64_archive() { rm -f "$1"; "$CLANGDIR/bin/llvm-ar" rcs "$1" "$t/f-arm64.o"; }
  why="an arm64 librecaulk.a"; want="librecaulk.a is not thin x86_64"
  bad arm64_archive "$t/bad/lib/rustlib/x86_64-apple-darwin/lib/librecaulk.a"
  why="no cargo-fmt"; want="lacks bin/cargo-fmt"
  bad rm "$t/bad/bin/cargo-fmt"
  echo "(arm64 fixture stages audited)"
else
  echo "(no arm64 fixture stages: this clang22 has no AArch64 backend)"
fi

if [ ! -e "$S/bin/rustc" ]; then echo "OK smoke-target (static; no cross stage built)"; exit 0; fi
audit "$S" > "$t/out" || { cat "$t/out"; fail "the cross stage at $S"; }
echo "OK smoke-target (static audit of the cross stage passed)"
