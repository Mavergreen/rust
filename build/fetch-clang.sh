#!/bin/sh
# platform: macOS-only -- pkgutil, shasum
#   usage: fetch-clang.sh     prints the extracted clang-22 prefix (holds bin/clang);
#          CLANG_VARIANT=cross|native picks the pkg; re-verified against SHA256SUMS every run
set -eu
. "$(cd "$(dirname "$0")" && pwd)/versions.sh"
KIND="${CLANG_VARIANT:-cross}"
TAG="$(tr -d ' \t\n' < "$CLANG_PIN_FILE")"
[ -n "$TAG" ] || { echo "FATAL: empty components/clang/version" >&2; exit 1; }
LINE="${TAG%%.*}"                                  # 22 from 22.1.1-mavericks.1
CACHE="$WORK/clang-dl"; OUT="$WORK/clang-$KIND-$TAG"
mkdir -p "$CACHE"
sums="$CACHE/SHA256SUMS-$TAG"
# spec: docs/superpowers/specs/2026-09-25-rust-plan3a-conformance-design.md "clang rename" --
#       Mavergreen/clang becomes Mavergreen/clang-22; try the new name first, then the old one.
base=""
for repo in clang-22 clang; do
  if curl -fsSL -o "$sums" "https://github.com/Mavergreen/$repo/releases/download/$TAG/SHA256SUMS"; then
    base="https://github.com/Mavergreen/$repo/releases/download/$TAG"; break
  fi
done
[ -n "$base" ] || { echo "FATAL: no SHA256SUMS for $TAG under Mavergreen/clang-22 or Mavergreen/clang" >&2; exit 1; }
pkg_name=""
for cand in "mavericks-clang-${LINE}-${KIND}-${TAG}.pkg" "clang-${LINE}-${KIND}-${TAG}.pkg"; do
  awk -v f="$cand" '$2==f {found=1} END{exit !found}' "$sums" && { pkg_name="$cand"; break; }
done
[ -n "$pkg_name" ] || { echo "FATAL: no $KIND .pkg for $TAG listed in SHA256SUMS" >&2; cat "$sums" >&2; exit 1; }
pkg="$CACHE/$pkg_name"
if [ ! -f "$pkg" ]; then tmp="$pkg.tmp.$$"; curl -fsSL -o "$tmp" "$base/$pkg_name"; mv "$tmp" "$pkg"; fi
want="$(awk -v f="$pkg_name" '$2==f {print $1}' "$sums")"
got="$(shasum -a 256 "$pkg" | awk '{print $1}')"
[ "$want" = "$got" ] || { echo "FATAL: clang pkg sha mismatch: $got != $want" >&2; rm -f "$pkg"; exit 1; }

exp="$CACHE/expanded-$KIND-$TAG"; rm -rf "$exp"
pkgutil --expand-full "$pkg" "$exp" 1>&2
# platform: pkgutil --expand-full recreates bin/clang as a symlink to clang-22
clangbin="$(find "$exp" \( -type f -o -type l \) -path '*/bin/clang' | head -1)"
[ -n "$clangbin" ] || { echo "FATAL: bin/clang not found in clang pkg payload" >&2; exit 1; }
prefix="$(cd "$(dirname "$clangbin")/.." && pwd)"
rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"; cp -R "$prefix" "$OUT"
[ -x "$OUT/bin/clang" ] && [ -x "$OUT/bin/clang++" ] || { echo "FATAL: extracted clang not executable" >&2; exit 1; }
echo "$OUT"
