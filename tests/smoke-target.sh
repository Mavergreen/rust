#!/bin/sh
# SKIP (77) until staged. Compile a std::time program with the cross rustc targeting x86_64-apple-darwin,
# assert the OUTPUT is 10.9-safe (arch x86_64 + 10.9 floor, no unresolved post-10.9 imports; the shim
# DEFINES clock_gettime). This is the in-CI equivalence proof for the absent 10.9 runner.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/build/versions.sh"
: "${SHIPYARD_SCRIPTS:?need shipyard}"
STAGE="$CROSS_STAGE_ROOT$CROSS_PREFIX"
RUSTC="$STAGE/bin/rustc"
[ -x "$RUSTC" ] || { echo "not built -- skipping"; exit 77; }

t="$(mktemp -d "${TMPDIR:-/tmp}/smoke-target.XXXXXX")"; trap 'rm -rf "$t"' EXIT   # template: 10.9 BSD mktemp requires one
# Exercise BOTH 10.9 backfilled paths, not just one: HashMap::new() pulls std's entropy source
# (CCRandomGenerateBytes, a 10.10 API we alias to arc4random_buf), SystemTime pulls clock_gettime, and
# a thread pulls the pthread/runtime paths. A hello that only touched std::time would pass even if a
# real user program failed to link HashMap — the gap this closes.
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
# The wrapper auto-links the polyfill because we pass --target x86_64-apple-darwin.
"$RUSTC" --target "$TARGET_TRIPLE" "$t/smoke.rs" -o "$t/smoke"
lipo -info "$t/smoke" | sed -n 's/.*: //p' | grep -qw x86_64 || { echo "FAIL: not x86_64"; exit 1; }

# The compat guard: the emitted binary must be 10.9-safe. Both post-10.9 APIs std references must be
# DEFINED by the linked shim (golang precedent for clock_gettime; CCRandomGenerateBytes is ours). If
# either shipped as an undefined import instead, the binary would crash on real 10.9 at first use.
MAVERICKS_REQUIRE_DEFINED_SYMBOLS='_clock_gettime _CCRandomGenerateBytes' \
  sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$t/smoke"

echo "OK smoke-target"
