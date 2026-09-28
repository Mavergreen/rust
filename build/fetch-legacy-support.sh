#!/bin/sh
# platform: macOS-only -- pkgutil, lipo
#   usage: fetch-legacy-support.sh     prints the extracted libMacportsLegacySupport.a; the
#          prebuilt x86_64/10.9 shim from the pinned Mavergreen/macports-legacy-support release,
#          re-verified against that release's SHA256SUMS on every run
set -eu
. "$(cd "$(dirname "$0")" && pwd)/versions.sh"
: "${MLS_VERSION:?set MLS_VERSION}"

OUT="$WORK/legacy-support"
A="$OUT/lib/libMacportsLegacySupport.a"
CACHE="$WORK/legacy-support-dl"
tag="$MLS_VERSION"
pkg_name="macports-legacy-support-$MLS_VERSION.pkg"
base="https://github.com/Mavergreen/macports-legacy-support/releases/download/$tag"

mkdir -p "$CACHE"
pkg="$CACHE/$pkg_name"; sums="$CACHE/SHA256SUMS"

if [ ! -f "$pkg" ]; then
  tmp="$pkg.tmp.$$"; curl -fsSL -o "$tmp" "$base/$pkg_name"; mv "$tmp" "$pkg"
fi
curl -fsSL -o "$sums" "$base/SHA256SUMS"
want=$(awk -v f="$pkg_name" '$2==f {print $1}' "$sums")
[ -n "$want" ] || { echo "FATAL: $pkg_name not listed in SHA256SUMS" >&2; exit 1; }
got=$(shasum -a 256 "$pkg" | awk '{print $1}')
[ "$want" = "$got" ] || { echo "FATAL: legacy-support pkg sha mismatch: $got != $want" >&2; rm -f "$pkg"; exit 1; }

exp="$CACHE/expanded"; rm -rf "$exp"
pkgutil --expand-full "$pkg" "$exp" 1>&2
a_src=$(find "$exp" -type f -name libMacportsLegacySupport.a | head -1)
[ -n "$a_src" ] || { echo "FATAL: libMacportsLegacySupport.a not found in pkg payload" >&2; exit 1; }
usrlocal=$(dirname "$(dirname "$a_src")")     # .../Payload/usr/local

rm -rf "$OUT"; mkdir -p "$OUT/lib" "$OUT/include"
cp "$usrlocal/lib/libMacportsLegacySupport.a" "$OUT/lib/"
cp -R "$usrlocal/include/LegacySupport" "$OUT/include/"
test -f "$A" || { echo "FATAL: no static .a extracted" >&2; exit 1; }

lipo -info "$A" 2>/dev/null | sed -n 's/.*: //p' | grep -qw x86_64 \
  || { echo "FATAL: $A has no x86_64 slice (archs: $(lipo -info "$A" 2>&1 | sed -n 's/.*: //p'))" >&2; exit 1; }

echo "$A"
