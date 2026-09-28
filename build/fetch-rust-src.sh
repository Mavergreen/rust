#!/bin/sh
# platform: macOS-only -- shasum
#   usage: fetch-rust-src.sh     prints the extracted source tree (holds x.py); verified
#          against static.rust-lang.org's own .sha256 for the pinned version
set -eu
. "$(cd "$(dirname "$0")" && pwd)/versions.sh"
CACHE="$WORK/rust-src-dl"; OUT="$WORK/rustc-$RUST_VERSION-src"
mkdir -p "$CACHE"
tarball="$CACHE/rustc-$RUST_VERSION-src.tar.xz"
if [ ! -f "$tarball" ]; then tmp="$tarball.tmp.$$"; curl -fsSL -o "$tmp" "$RUST_SRC_URL"; mv "$tmp" "$tarball"; fi
want="$(curl -fsSL "$RUST_SRC_SHA_URL" | awk '{print $1}')"
[ -n "$want" ] || { echo "FATAL: no upstream .sha256 for $RUST_VERSION" >&2; exit 1; }
got="$(shasum -a 256 "$tarball" | awk '{print $1}')"
[ "$want" = "$got" ] || { echo "FATAL: rust src sha mismatch: $got != $want" >&2; rm -f "$tarball"; exit 1; }
rm -rf "$OUT"
tar -xf "$tarball" -C "$WORK"
[ -f "$OUT/x.py" ] || { echo "FATAL: x.py not found after extract" >&2; exit 1; }
echo "$OUT"
