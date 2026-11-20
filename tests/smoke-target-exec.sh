#!/bin/sh
# platform: macOS-only -- runs the arm64 rust-cross stage, so only on an Apple Silicon Mac
#   usage: smoke-target-exec.sh
#          The executing half of the cross stage's smoke: the staged rustc compiles and links a 10.9
#          x86_64 program, with the pinned 10.9 SDK and through the build's clang22 clang++, and the
#          compat guard reads both. It skips anywhere but an Apple Silicon Mac, decided from uname -s
#          and hw.optional.arm64. smoke-target.sh is the static half.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
RUST_VARIANT=cross; export RUST_VARIANT
. "$ROOT/build/versions.sh"; . "$ROOT/build/lib-rust.sh"
: "${SHIPYARD_SCRIPTS:?need shipyard}"
arm="$(sysctl -n hw.optional.arm64 2>/dev/null)" || arm=0
if [ "$(uname -s)" != Darwin ] || [ "$arm" != 1 ]; then
  echo "SKIP: the cross stage runs on an Apple Silicon Mac, and this is $(uname -s) $(uname -m)"; exit 77
fi
macho_tools
STAGE="$CROSS_STAGE_ROOT$CROSS_PREFIX"
RUSTC="$STAGE/bin/rustc"
[ -x "$RUSTC" ] || { echo "not built -- skipping"; exit 77; }

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
SDKROOT="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64)" "$RUSTC" --target "$TARGET_TRIPLE" "$t/smoke.rs" -o "$t/smoke"
"$LIPO" -info "$t/smoke" | sed -n 's/.*: //p' | grep -qw x86_64 || { echo "FAIL: not x86_64"; exit 1; }

MAVERICKS_REQUIRE_DEFINED_SYMBOLS='_clock_gettime _CCRandomGenerateBytes' \
  sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$t/smoke"

CLANGXX="$WORK/clang22-$(tr -d ' \t\n' < "$CLANG_PIN_FILE")/bin/clang++"
[ -x "$CLANGXX" ] || { echo "FAIL: the cross build's clang22-cross is not at $CLANGXX, so the clang22 link was not checked"; exit 1; }
env -u SDKROOT "$RUSTC" --target "$TARGET_TRIPLE" -C linker="$CLANGXX" "$t/smoke.rs" -o "$t/smoke-clang22" \
  || { echo "FAIL: linking through clang22-cross's clang++ (codex-cli's setup) failed"; exit 1; }
"$LIPO" -info "$t/smoke-clang22" | sed -n 's/.*: //p' | grep -qw x86_64 || { echo "FAIL: clang22 link not x86_64"; exit 1; }
MAVERICKS_REQUIRE_DEFINED_SYMBOLS='_clock_gettime _CCRandomGenerateBytes' \
  sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$t/smoke-clang22"

echo "OK smoke-target-exec"
