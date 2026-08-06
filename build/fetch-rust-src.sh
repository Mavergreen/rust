#!/bin/sh
# Fetch the Rust source tarball for the pinned RUST_VERSION and verify it against upstream's own
# published .sha256 (static.rust-lang.org). A checksum upstream publishes for the pinned version makes
# a Renovate bump self-contained. Prints the extracted source tree path (contains x.py) on stdout.
set -eu
. "$(cd "$(dirname "$0")" && pwd)/versions.sh"
CACHE="$WORK/rust-src-dl"; OUT="$WORK/rustc-$RUST_VERSION-src"
mkdir -p "$CACHE"
tarball="$CACHE/rustc-$RUST_VERSION-src.tar.xz"
if [ ! -f "$tarball" ]; then tmp="$tarball.tmp.$$"; curl -fsSL -o "$tmp" "$RUST_SRC_URL"; mv "$tmp" "$tarball"; fi
# upstream .sha256 is "<hex>  rustc-<ver>-src.tar.xz"
want="$(curl -fsSL "$RUST_SRC_SHA_URL" | awk '{print $1}')"
[ -n "$want" ] || { echo "FATAL: no upstream .sha256 for $RUST_VERSION" >&2; exit 1; }
got="$(shasum -a 256 "$tarball" | awk '{print $1}')"
[ "$want" = "$got" ] || { echo "FATAL: rust src sha mismatch: $got != $want" >&2; rm -f "$tarball"; exit 1; }
rm -rf "$OUT"
# the tarball extracts to rustc-<ver>-src/ ; extract into WORK
tar -xf "$tarball" -C "$WORK"
[ -f "$OUT/x.py" ] || { echo "FATAL: x.py not found after extract" >&2; exit 1; }
echo "$OUT"
