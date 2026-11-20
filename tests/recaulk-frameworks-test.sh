#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
t="$(mktemp -d "${TMPDIR:-/tmp}/recaulk-fw.XXXXXX")"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; exit 1; }
. "$ROOT/tests/lib/clang22.sh"
pin="$(tr -d ' \t\n' < "$ROOT/components/recaulk/version")"
link_bare() {
  fixture_cc -dynamiclib -Wl,-force_load,"$1/lib/librecaulk.a" -o "$t/bare.dylib" 2> "$t/err"
}
for f in build/fetch-stage0.sh build/lib-rust.sh; do
  ! grep -q 'ApplicationServices' "$ROOT/$f" || fail "$f still names ApplicationServices: Recaulk $pin carries its own link needs as LC_LINKER_OPTION"
done
rc="$(sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" recaulk "$pin" "$t/pin")" \
  || { echo "Recaulk $pin could not be fetched -- skipping"; exit 77; }
link_bare "$rc" || { cat "$t/err"; fail "force-loading Recaulk $pin with no -framework or -l flag leaves symbols undefined"; }
old=20261118.1
if [ "$pin" != "$old" ]; then
  ro="$(sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" recaulk "$old" "$t/old")" \
    || { echo "Recaulk $old could not be fetched -- skipping"; exit 77; }
  if link_bare "$ro"; then fail "Recaulk $old links bare, so this test no longer shows what the pin changed"; fi
fi
echo "OK recaulk-frameworks-test (Recaulk $pin links bare; $old does not)"
