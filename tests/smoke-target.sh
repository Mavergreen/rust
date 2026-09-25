#!/bin/sh
# platform: macOS-only -- lipo, and assert_binary_compatible.sh's otool/nm
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/build/versions.sh"
: "${SHIPYARD_SCRIPTS:?need shipyard}"
STAGE="$CROSS_STAGE_ROOT$CROSS_PREFIX"
RUSTC="$STAGE/bin/rustc"
[ -x "$RUSTC" ] || { echo "not built -- skipping"; exit 77; }

t="$(mktemp -d "${TMPDIR:-/tmp}/smoke-target.XXXXXX")"; trap 'rm -rf "$t"' EXIT
cat > "$t/smoke.rs" <<'EOF'
use std::collections::HashMap;
use std::time::SystemTime;
fn main() {
    let mut m = HashMap::new();
    m.insert("mavericks", 109);                       // -> CCRandomGenerateBytes (HashMap seed)
    let _ = SystemTime::now();                         // -> clock_gettime
    let n = std::thread::spawn(|| 42).join().unwrap(); // -> pthread/runtime
    println!("smoke {:?} {}", m.get("mavericks"), n);
}
EOF
"$RUSTC" --target "$TARGET_TRIPLE" "$t/smoke.rs" -o "$t/smoke"
lipo -info "$t/smoke" | sed -n 's/.*: //p' | grep -qw x86_64 || { echo "FAIL: not x86_64"; exit 1; }

MAVERICKS_REQUIRE_DEFINED_SYMBOLS='_clock_gettime _CCRandomGenerateBytes' \
  sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$t/smoke"

echo "OK smoke-target"
