#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
S="$ROOT/build/rehash-vendored.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/rehash.XXXXXX")"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; exit 1; }
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'; }
Z=0000000000000000000000000000000000000000000000000000000000000000
[ -f "$S" ] || fail "build/rehash-vendored.sh is missing"

c="$t/src/vendor/foo-sys-1.0.0+2.3"; mkdir -p "$c/src/net" "$t/p" "$t/src/library"
echo patched > "$c/src/net/tls.c"; echo kept > "$c/src/other.c"; echo std > "$t/src/library/lib.rs"
printf '{"files":{"src/net/tls.c":"%s","src/other.c":"%s"},"package":"%s"}' "$Z" "$Z" "$Z" > "$c/.cargo-checksum.json"
printf -- '--- a/vendor/foo-sys-1.0.0+2.3/src/net/tls.c\n+++ b/vendor/foo-sys-1.0.0+2.3/src/net/tls.c\n@@ -1 +1 @@\n-x\n+patched\n' > "$t/p/0002-foo.patch"
printf -- '--- a/library/lib.rs\n+++ b/library/lib.rs\n@@ -1 +1 @@\n-x\n+std\n' > "$t/p/0001-std.patch"

sh "$S" "$t/src" "$t/p" || fail "rehash failed on a tree whose patched vendored file is listed"
j="$(cat "$c/.cargo-checksum.json")"
case "$j" in *"\"src/net/tls.c\":\"$(sha "$c/src/net/tls.c")\""*) ;; *) fail "the patched file's entry must carry its new SHA-256, got: $j" ;; esac
case "$j" in *"\"src/other.c\":\"$Z\""*) ;; *) fail "an unpatched file's entry must be left alone, got: $j" ;; esac
case "$j" in *"\"package\":\"$Z\"}") ;; *) fail "the package digest (of the .crate, not the tree) must be left alone, got: $j" ;; esac
[ -z "$(find "$t/src" -name '*.cargo-checksum*' ! -name .cargo-checksum.json)" ] || fail "no temporary file is left beside the checksum"

sh "$S" "$t/src" "$t/p" || fail "a second run must succeed"
[ "$(cat "$c/.cargo-checksum.json")" = "$j" ] || fail "a second run must change nothing"

printf -- '--- a/vendor/foo-sys-1.0.0+2.3/src/new.c\n+++ b/vendor/foo-sys-1.0.0+2.3/src/new.c\n@@ -1 +1 @@\n-x\n+y\n' > "$t/p/0003-unlisted.patch"
echo y > "$c/src/new.c"
if sh "$S" "$t/src" "$t/p" 2>/dev/null; then fail "a patched vendored file with no checksum entry is refused: no patch here adds a file to a vendored crate"; fi
rm "$t/p/0003-unlisted.patch"

grep -q 'rehash-vendored.sh' "$ROOT/build/fetch-rust-src.sh" || fail "fetch-rust-src.sh re-hashes vendored files after applying patches/"
a="$(grep -n 'apply_patches.sh' "$ROOT/build/fetch-rust-src.sh" | cut -d: -f1)"; r="$(grep -n 'rehash-vendored.sh' "$ROOT/build/fetch-rust-src.sh" | cut -d: -f1)"
[ "$a" -lt "$r" ] || fail "re-hashing runs after the patches are applied"
echo "PASS rehash-vendored"
