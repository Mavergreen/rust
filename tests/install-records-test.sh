#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
fail() { echo "FAIL $1"; exit 1; }
. "$ROOT/build/versions.sh"; . "$ROOT/build/lib-rust.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/install-records.XXXXXX")"; trap 'rm -rf "$t"' EXIT
r="$t/work/stage"; s="$r/usr/local/mavergreen/rust"; mkdir -p "$s/lib/rustlib"
mkdir -p "$s/bin" "$s/share/doc/cargo"; : > "$s/bin/cargo"
printf 'file:%s/bin/cargo\nfile:%s/lib/libpruned-0123456789abcdef.dylib\ndir:%s/share/doc/cargo\n' "$s" "$s" "$s" > "$s/lib/rustlib/manifest-cargo"
printf '$ cp %s/x %s/bin/cargo\n' "$t/work" "$s" > "$s/lib/rustlib/install.log"
rewrite_install_records "$r" "$s"
[ "$(cat "$s/lib/rustlib/manifest-cargo")" = "file:/usr/local/mavergreen/rust/bin/cargo
dir:/usr/local/mavergreen/rust/share/doc/cargo" ] || fail "a manifest names installed paths, not the staging root, and drops a file the stage no longer has (a pruned proc-macro dylib): $(cat "$s/lib/rustlib/manifest-cargo")"
[ ! -e "$s/lib/rustlib/install.log" ] || fail "install.log, the build's own command log full of staging paths, is not shipped"
for b in build-native build-cross build-linux; do
  grep -q '^rewrite_install_records ' "$ROOT/build/$b.sh" || fail "build/$b.sh rewrites the install records before it verifies the stage"
done
echo "PASS install-records"
