#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
fail() { echo "FAIL $1"; exit 1; }
. "$ROOT/build/package-lib.sh"
command -v variant_requires >/dev/null 2>&1 || fail "package-lib.sh must define variant_requires"
[ "$(variant_requires native)" = clang22 ] \
  || fail "the native pkg requires clang22, its default linker on 10.9: got '$(variant_requires native)'"
[ -z "$(variant_requires cross)" ] || fail "rust-cross requires nothing: got '$(variant_requires cross)'"
body="$(sed -n '/^package_variant() {/,/^}/p' "$ROOT/build/package-lib.sh")"
case "$body" in *'variant_requires "$v"'*'--requires'*) : ;; *) fail "package_variant passes each of variant_requires' products to stage_product as --requires" ;; esac
echo "OK package-requires-test"
