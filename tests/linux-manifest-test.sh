#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
fail() { echo "FAIL $1"; exit 1; }
t="$(mktemp -d "${TMPDIR:-/tmp}/linux-manifest.XXXXXX")"; trap 'rm -rf "$t"' EXIT
. "$ROOT/build/package-lib.sh"
command -v write_linux_manifest >/dev/null 2>&1 || fail "package-lib.sh must define write_linux_manifest"
mkdir -p "$t/prefix/bin"
write_linux_manifest "$t/prefix" 1.99.1-mavericks.99 > "$t/out" 2>&1 || { cat "$t/out"; fail "write_linux_manifest failed"; }
M="$t/prefix/mavergreen.plist"
[ -f "$M" ] || fail "write_linux_manifest leaves the manifest at PREFIX/mavergreen.plist, where install-products.sh reads it"
S="$(sh "$SHIPYARD_SCRIPTS/fetch_stevedore.sh")"
get() { "$S" plist get "$M" "$1"; }
[ "$(get identifier)" = dev.mavergreen.rust.rust ] || fail "the identifier is rust's pkg's: got '$(get identifier)'"
[ "$(get product)" = rust ] || fail "the product is rust: got '$(get product)'"
[ "$(get version)" = 1.99.1-mavericks.99 ] || fail "the version is the release's: got '$(get version)'"
[ -z "$(get appcast)" ] || fail "the tarball installs no updater, so its manifest names no appcast: got '$(get appcast)'"
. "$SHIPYARD_SCRIPTS/lib/requires.sh"
req="$(mavergreen_requires "$S" "$M" "$t/err")" || { cat "$t/err"; fail "the manifest's requires cannot be read"; }
[ "$req" = "$(variant_requires native)" ] || fail "the tarball requires what the pkg does: got '$req'"
for e in $RUST_MANIFEST_EXCLUDES; do grep -q "<string>$e</string>" "$M" || fail "the manifest excludes $e, as the pkg's does"; done
[ ! -e "$t/prefix/usr" ] || fail "write_linux_manifest leaves nothing in PREFIX but the manifest"
echo "OK linux-manifest-test"
