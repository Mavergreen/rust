#!/bin/sh
# platform: macOS-only -- builds a dylib with clang-22 and injects it via dyld
#   usage: fetch-stage0-onbox.sh CLANGDIR POLY_A      prints STAGE0DIR
#          Makes the official x86_64 rustc/cargo of the SAME version run on 10.9, for x.py's stage0
#          (with local-rebuild). Nothing the build ships is injected.
# spec: docs/superpowers/specs/2026-09-25-rust-plan3a-conformance-design.md decision 4
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/versions.sh"; . "$HERE/lib-rust.sh"
CLANGDIR="${1:?usage: fetch-stage0-onbox.sh CLANGDIR POLY_A}"; POLY_A="${2:?POLY_A}"
H=x86_64-apple-darwin; S0="$WORK/stage0-onbox"; CACHE="$WORK/stage0-dl"; mkdir -p "$CACHE" "$S0"
name="rust-$RUST_VERSION-$H"; tb="$CACHE/$name.tar.xz"
url="https://static.rust-lang.org/dist/$name.tar.xz"
[ -f "$tb" ] || { curl -fsSL -o "$tb.tmp" "$url"; mv "$tb.tmp" "$tb"; }
want="$(curl -fsSL "$url.sha256" | awk '{print $1}')"
[ -n "$want" ] || { echo "FATAL: no upstream .sha256 for $name" >&2; exit 1; }
got="$(shasum -a 256 "$tb" | awk '{print $1}')"
[ "$want" = "$got" ] || { echo "FATAL: stage0 sha mismatch: $got != $want" >&2; rm -f "$tb"; exit 1; }
rm -rf "$S0/dist"; mkdir -p "$S0/dist"; tar -xf "$tb" -C "$S0/dist"
D="$S0/dist/$name"
cp -R "$D/rust-std-$H/lib/rustlib/$H" "$D/rustc/lib/rustlib/"
# platform: clang-22's clang.cfg links the shim archive on its own
# platform: dyld's flat-namespace lookup finds only the symbols an injected dylib exports
# platform: -all_load also forces compiler-rt's os_version_check.o, which needs
#           _availability_version_check, absent from 10.9's libSystem
"$CLANGDIR/bin/clang" --no-default-config -dynamiclib -mmacosx-version-min=10.9 \
  -Wl,-force_load,"$POLY_A" -framework CoreFoundation -framework Security -framework CoreServices -lobjc \
  -install_name "$S0/libMavericksLegacySupport.dylib" -o "$S0/libMavericksLegacySupport.dylib" >&2
write_stage0_wrappers "$S0" "$D"
echo "$S0"
