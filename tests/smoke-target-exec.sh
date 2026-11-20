#!/bin/sh
# platform: macOS-only -- runs the arm64 rust-cross stage, so only on an Apple Silicon Mac
#   usage: smoke-target-exec.sh [PREFIX]
#          The executing half of the cross stage's smoke: the staged rustc compiles and links a 10.9
#          x86_64 program, with the pinned 10.9 SDK and through the build's clang22 clang++, and the
#          compat guard reads both. It skips anywhere but an Apple Silicon Mac, decided from uname -s
#          and hw.optional.arm64. smoke-target.sh is the static half.
#          PREFIX is an installed rust-cross, as release.yml's modern-smoke installs it. Then the smoke
#          reads it rather than the stage, links through the pinned clang22 that fetch_clang22.sh gives
#          with the 10.9 SDK as SDKROOT, and also checks rustc -vV and cargo -V and has cargo build a
#          crate that depends on itoa from crates.io, x86_64 with minos 10.9. It never runs the output.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
RUST_VARIANT=cross; export RUST_VARIANT
. "$ROOT/build/versions.sh"; . "$ROOT/build/lib-rust.sh"
: "${SHIPYARD_SCRIPTS:?need shipyard}"
arm="$(sysctl -n hw.optional.arm64 2>/dev/null)" || arm=0
if [ "$(uname -s)" != Darwin ] || [ "$arm" != 1 ]; then
  echo "SKIP: the cross stage runs on an Apple Silicon Mac, and this is $(uname -s) $(uname -m)"; exit 77
fi
PREFIX="${1:-}"
if [ -n "$PREFIX" ]; then
  RUSTC="$PREFIX/bin/rustc"
  [ -x "$RUSTC" ] || { echo "FAIL: no rustc at $RUSTC, where the rust-cross pkg installs it"; exit 1; }
  CLANGDIR="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$CLANG_PIN_DIR")"
  CLANGXX="$CLANGDIR/bin/clang++"
else
  RUSTC="$CROSS_STAGE_ROOT$CROSS_PREFIX/bin/rustc"
  [ -x "$RUSTC" ] || { echo "not built -- skipping"; exit 77; }
  CLANGXX="$WORK/clang22-$(tr -d ' \t\n' < "$CLANG_PIN_FILE")/bin/clang++"
fi
macho_tools

t="$(mktemp -d "${TMPDIR:-/tmp}/smoke-target.XXXXXX")"; trap 'rm -rf "$t"' EXIT
cat > "$t/smoke.rs" <<'RS'
use std::collections::HashMap;
use std::time::SystemTime;
fn main() {
    let mut m = HashMap::new();
    m.insert("mavericks", 109);                       // -> CCRandomGenerateBytes (HashMap seed)
    let _ = SystemTime::now();                         // -> clock_gettime
    let n = std::thread::spawn(|| 42).join().unwrap(); // -> pthread/runtime
    println!("smoke {:?} {}", m.get("mavericks"), n);
}
RS
# spec: shipyard docs/superpowers/specs/2026-09-24-sdk-pinning-design.md, decision 1 -- a 10.9
#       binary records the pinned 10.9 SDK; rustc links against $SDKROOT when it is set
S9="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64)"
SDKROOT="$S9" "$RUSTC" --target "$TARGET_TRIPLE" "$t/smoke.rs" -o "$t/smoke"
"$LIPO" -info "$t/smoke" | sed -n 's/.*: //p' | grep -qw x86_64 || { echo "FAIL: not x86_64"; exit 1; }

MAVERICKS_REQUIRE_DEFINED_SYMBOLS='_clock_gettime _CCRandomGenerateBytes' \
  sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$t/smoke"

[ -x "$CLANGXX" ] || { echo "FAIL: clang22-cross is not at $CLANGXX, so the clang22 link was not checked"; exit 1; }
if [ -n "$PREFIX" ]; then
  SDKROOT="$S9" "$RUSTC" --target "$TARGET_TRIPLE" -C linker="$CLANGXX" "$t/smoke.rs" -o "$t/smoke-clang22" \
    || { echo "FAIL: linking through clang22-cross's clang++ with the 10.9 SDK as SDKROOT (codex-cli's setup) failed"; exit 1; }
else
  env -u SDKROOT "$RUSTC" --target "$TARGET_TRIPLE" -C linker="$CLANGXX" "$t/smoke.rs" -o "$t/smoke-clang22" \
    || { echo "FAIL: linking through clang22-cross's clang++ (codex-cli's setup) failed"; exit 1; }
fi
"$LIPO" -info "$t/smoke-clang22" | sed -n 's/.*: //p' | grep -qw x86_64 || { echo "FAIL: clang22 link not x86_64"; exit 1; }
MAVERICKS_REQUIRE_DEFINED_SYMBOLS='_clock_gettime _CCRandomGenerateBytes' \
  sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$t/smoke-clang22"

[ -n "$PREFIX" ] || { echo "OK smoke-target-exec"; exit 0; }

vv="$("$RUSTC" -vV)" || { echo "FAIL: $RUSTC -vV"; exit 1; }
printf '%s\n' "$vv" | grep -qx 'host: aarch64-apple-darwin' || { echo "FAIL: rustc -vV names no arm64 host: $vv"; exit 1; }
printf '%s\n' "$vv" | grep -qx "release: $RUST_VERSION" || { echo "FAIL: rustc -vV names no release $RUST_VERSION: $vv"; exit 1; }
"$PREFIX/bin/cargo" -V || { echo "FAIL: $PREFIX/bin/cargo -V"; exit 1; }
A="$t/app"; mkdir -p "$A/src"
printf '[package]\nname = "smoke"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\nitoa = "1"\n' > "$A/Cargo.toml"
printf 'fn main() { println!("{}", itoa::Buffer::new().format(109)); }\n' > "$A/src/main.rs"
CARGO_HOME="$t/cargo-home" CARGO_TARGET_DIR="$t/target" RUSTC="$RUSTC" SDKROOT="$S9" \
  "$PREFIX/bin/cargo" build --manifest-path "$A/Cargo.toml" --target "$TARGET_TRIPLE" \
  || { echo "FAIL: cargo build of a crate using itoa for $TARGET_TRIPLE"; exit 1; }
out="$t/target/$TARGET_TRIPLE/debug/smoke"
"$LIPO" -info "$out" | grep -Eq 'architecture: x86_64 *$' || { echo "FAIL: the itoa crate's output is not thin x86_64"; exit 1; }
minos="$("$OTOOL" -l "$out" | awk '$1 == "cmd" { v = ($2 == "LC_VERSION_MIN_MACOSX"); b = ($2 == "LC_BUILD_VERSION") }
  (v && $1 == "version") || (b && $1 == "minos") { print $2; exit }')"
[ "$minos" = 10.9 ] || { echo "FAIL: the itoa crate's output records minos '$minos', not 10.9"; exit 1; }
echo "OK smoke-target-exec ($PREFIX)"
