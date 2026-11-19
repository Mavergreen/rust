#!/bin/sh
# platform: host-agnostic
#   usage: fetch-stage0.sh CLANGDIR RECAULK_A     prints STAGE0DIR
#          The official rustc/cargo of the SAME version, for x.py's stage0 (with local-rebuild).
#          On a Mac it makes the x86_64-apple-darwin ones run on 10.9: it builds a dylib with clang-22
#          and injects it via dyld. Nothing the build ships is injected. On Linux it unpacks the
#          x86_64-unknown-linux-gnu ones as they are; CLANGDIR and RECAULK_A go unused there.
#          MAVERICKS_STAGE0_BASE replaces https://static.rust-lang.org/dist on Linux.
# spec: docs/superpowers/specs/2026-09-25-rust-plan3a-conformance-design.md decision 4
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/versions.sh"; . "$HERE/lib-rust.sh"
. "$HERE/msc.sh"; . "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
CLANGDIR="${1:?usage: fetch-stage0.sh CLANGDIR RECAULK_A}"; RECAULK_A="${2:?RECAULK_A}"
if [ "$(uname -s)" = Linux ]; then
  H=x86_64-unknown-linux-gnu; S0="$WORK/stage0"; CACHE="$WORK/stage0-dl"; mkdir -p "$CACHE" "$S0"
  name="rust-$RUST_VERSION-$H"; tb="$CACHE/$name.tar.xz"
  url="${MAVERICKS_STAGE0_BASE:-https://static.rust-lang.org/dist}/$name.tar.xz"
  want="$(shipyard_curl "$url.sha256" - | awk '{print $1}')"
  [ -n "$want" ] || { echo "FATAL: no upstream .sha256 for $name" >&2; exit 1; }
  shipyard_fetch_verified "$url" "$want" "$CACHE" "$name.tar.xz" \
    || { echo "FATAL: $url did not verify against upstream's .sha256" >&2; exit 1; }
  rm -rf "$S0/dist"; mkdir -p "$S0/dist"; tar -xf "$tb" -C "$S0/dist"
  D="$S0/dist/$name"
  cp -R "$D/rust-std-$H/lib/rustlib/$H" "$D/rustc/lib/rustlib/"
  mkdir -p "$S0/bin"
  for b in rustc cargo; do
    printf '#!/bin/sh\nexec "%s/%s/bin/%s" "$@"\n' "$D" "$b" "$b" > "$S0/bin/$b"; chmod +x "$S0/bin/$b"
  done
  echo "$S0"; exit 0
fi
H=x86_64-apple-darwin; S0="$WORK/stage0-onbox"; CACHE="$WORK/stage0-dl"; mkdir -p "$CACHE" "$S0"
name="rust-$RUST_VERSION-$H"; tb="$CACHE/$name.tar.xz"
url="https://static.rust-lang.org/dist/$name.tar.xz"
want="$(shipyard_curl "$url.sha256" - | awk '{print $1}')"
[ -n "$want" ] || { echo "FATAL: no upstream .sha256 for $name" >&2; exit 1; }
shipyard_fetch_verified "$url" "$want" "$CACHE" "$name.tar.xz" \
  || { echo "FATAL: $url did not verify against upstream's .sha256" >&2; exit 1; }
rm -rf "$S0/dist"; mkdir -p "$S0/dist"; tar -xf "$tb" -C "$S0/dist"
D="$S0/dist/$name"
cp -R "$D/rust-std-$H/lib/rustlib/$H" "$D/rustc/lib/rustlib/"
# platform: clang-22's clang.cfg links Recaulk on its own
# platform: dyld's flat-namespace lookup finds only the symbols an injected dylib exports
# platform: -all_load also forces compiler-rt's os_version_check.o, which needs
#           _availability_version_check, absent from 10.9's libSystem
# platform: -force_load takes librecaulk.a's C++ catch rules too, which call 10.9's libc++abi
# platform: -force_load takes Recaulk's CGColorCreateSRGB back-fill too, which calls CoreGraphics, a
#           subframework of ApplicationServices on 10.9
"$CLANGDIR/bin/clang" --no-default-config -dynamiclib -mmacosx-version-min=10.9 \
  -Wl,-force_load,"$RECAULK_A" -framework CoreFoundation -framework Security -framework CoreServices -framework ApplicationServices -lobjc -lc++abi \
  -install_name "$S0/librecaulk-stage0.dylib" -o "$S0/librecaulk-stage0.dylib" >&2
write_stage0_wrappers "$S0" "$D"
echo "$S0"
