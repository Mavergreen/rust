#!/bin/sh
# SKIP (77) until staged. Compile a std::time program with the cross rustc targeting x86_64-apple-darwin,
# assert the OUTPUT is 10.9-safe (arch x86_64 + 10.9 floor, no unresolved post-10.9 imports; the shim
# DEFINES clock_gettime). This is the in-CI equivalence proof for the absent 10.9 runner.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/build/versions.sh"
: "${MSC_SCRIPTS:?need shared-cmake}"
STAGE="$WORK/stage$CROSS_PREFIX"
RUSTC="$STAGE/bin/rustc"
[ -x "$RUSTC" ] || { echo "not built -- skipping"; exit 77; }

t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
cat > "$t/hello.rs" <<'EOF'
use std::time::SystemTime;
fn main() {
    let now = SystemTime::now();
    println!("hello mavericks {:?}", now);
}
EOF
# The wrapper auto-links the polyfill because we pass --target x86_64-apple-darwin.
"$RUSTC" --target "$TARGET_TRIPLE" "$t/hello.rs" -o "$t/hello"
lipo -archs "$t/hello" | grep -qw x86_64 || { echo "FAIL: not x86_64"; exit 1; }

# The compat guard: the emitted binary must be 10.9-safe. Because std uses clock_gettime and we link
# the legacy-support shim that DEFINES it, require that symbol to be DEFINED (golang precedent).
MAVERICKS_REQUIRE_DEFINED_SYMBOLS='_clock_gettime' \
  sh "$MSC_SCRIPTS/assert_binary_compatible.sh" "$t/hello"

echo "OK smoke-target"
