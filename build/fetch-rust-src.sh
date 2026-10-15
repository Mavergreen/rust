#!/bin/sh
# platform: macOS-only -- shasum
#   usage: fetch-rust-src.sh     prints the extracted source tree (holds x.py); verified
#          against static.rust-lang.org's own .sha256 for the pinned version
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"; . "$HERE/msc.sh"; . "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
CACHE="$WORK/rust-src-dl"; OUT="$WORK/rustc-$RUST_VERSION-src"
mkdir -p "$CACHE"
tarball="$CACHE/rustc-$RUST_VERSION-src.tar.xz"
want="$(shipyard_curl "$RUST_SRC_SHA_URL" - | awk '{print $1}')"
[ -n "$want" ] || { echo "FATAL: no upstream .sha256 for $RUST_VERSION" >&2; exit 1; }
shipyard_fetch_verified "$RUST_SRC_URL" "$want" "$CACHE" "${tarball##*/}" \
  || { echo "FATAL: $RUST_SRC_URL did not verify against upstream's .sha256" >&2; exit 1; }
rm -rf "$OUT"
tar -xf "$tarball" -C "$WORK"
[ -f "$OUT/x.py" ] || { echo "FATAL: x.py not found after extract" >&2; exit 1; }
echo "$OUT"
