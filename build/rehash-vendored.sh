#!/bin/sh
# platform: host-agnostic
#   usage: rehash-vendored.sh SRC PATCHDIR   for every vendor/<crate>/<file> a patch in PATCHDIR changes, writes
#          the file's new SHA-256 into SRC/vendor/<crate>/.cargo-checksum.json, so cargo accepts the patched crate
set -eu
SRC="${1:?usage: rehash-vendored.sh SRC PATCHDIR}"; PATCHES="${2:?PATCHDIR}"
# platform: a Mac has shasum and no sha256sum; a minimal Linux image has only sha256sum
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'; }
for p in "$PATCHES"/*.patch; do
  [ -f "$p" ] || continue
  sed -n 's|^+++ b/\(vendor/[^/]*/[^[:space:]]*\).*|\1|p' "$p"
done | sort -u | while read -r f; do
  crate="${f#vendor/}"; rel="${crate#*/}"; crate="${crate%%/*}"
  j="$SRC/vendor/$crate/.cargo-checksum.json"
  [ -f "$SRC/$f" ] && [ -f "$j" ] || { echo "rehash-vendored: $f or its crate's .cargo-checksum.json is missing" >&2; exit 1; }
  awk -v k="\"$rel\":\"" -v h="$(sha "$SRC/$f")" '{
      i = index($0, k); if (!i) exit 1
      s = i + length(k); printf "%s%s%s", substr($0, 1, s - 1), h, substr($0, s + 64)
    }' "$j" > "$j.new" || { rm -f "$j.new"; echo "rehash-vendored: $j does not list $rel" >&2; exit 1; }
  mv "$j.new" "$j"
done
