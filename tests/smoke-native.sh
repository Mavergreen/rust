#!/bin/sh
# SKIP (77) until the native toolchain is staged. Compile the HashMap+SystemTime+thread stress program
# with the NATIVE rustc and assert the output is 10.9-safe (both 10.9 shims DEFINED). Unlike the cross
# smoke, NO --target is passed: the native compiler's DEFAULT target IS x86_64/10.9, and wrap_rustc_native
# auto-links the polyfill unconditionally. On a real 10.9 box the binary also RUNS; on the arm64 builder
# it runs under Rosetta (best-effort) -- either way the compat guard is the gate.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/build/versions.sh"
: "${SHIPYARD_SCRIPTS:?need shipyard}"
STAGE="$NATIVE_STAGE_ROOT$NATIVE_PREFIX"
RUSTC="$STAGE/bin/rustc"
[ -x "$RUSTC" ] || { echo "not built -- skipping"; exit 77; }

t="$(mktemp -d "${TMPDIR:-/tmp}/mavnat.XXXXXX")"; trap 'rm -rf "$t"' EXIT
cat > "$t/smoke.rs" <<'EOF'
use std::collections::HashMap;
use std::time::SystemTime;
fn main() {
    let mut m = HashMap::new();
    m.insert("mavericks", 109);                        // -> CCRandomGenerateBytes (HashMap seed)
    let _ = SystemTime::now();                         // -> clock_gettime
    let n = std::thread::spawn(|| 42).join().unwrap(); // -> pthread/runtime
    println!("smoke {:?} {}", m.get("mavericks"), n);
}
EOF
# No --target: the native compiler defaults to x86_64/10.9 and auto-links the polyfill (wrap_rustc_native).
"$RUSTC" "$t/smoke.rs" -o "$t/smoke"
lipo -info "$t/smoke" 2>/dev/null | grep -q x86_64 || { echo "FAIL: not x86_64"; exit 1; }

MAVERICKS_REQUIRE_DEFINED_SYMBOLS='_clock_gettime _CCRandomGenerateBytes' \
  sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$t/smoke"

# If we're on genuine 10.9 (x86_64), also RUN it -- the flagship proof the native variant exists for.
if [ "$(uname -m)" = x86_64 ] && [ "$(sw_vers -productVersion 2>/dev/null | cut -d. -f1,2)" = 10.9 ]; then
  out="$("$t/smoke")"; echo "$out"
  [ "$out" = 'smoke Some(109) 42' ] || { echo "FAIL: unexpected native output: $out"; exit 1; }
  echo "(ran natively on real 10.9)"
fi
echo "OK smoke-native"
