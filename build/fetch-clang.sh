#!/bin/sh
# Fetch the prebuilt clang-22 CROSS toolchain (arm64, targets x86_64-apple-macos10.9) from the pinned
# ModernMavericks/clang release. Integrity re-checked against the release's SHA256SUMS EVERY run.
# Prints the path of the extracted toolchain prefix (contains bin/clang) on stdout; logs to stderr.
set -eu
. "$(cd "$(dirname "$0")" && pwd)/versions.sh"
TAG="$(tr -d ' \t\n' < "$CLANG_PIN_FILE")"
[ -n "$TAG" ] || { echo "FATAL: empty components/clang/version" >&2; exit 1; }
LINE="${TAG%%.*}"                                  # 22 from 22.1.1-mavericks.1
base="https://github.com/ModernMavericks/clang/releases/download/$TAG"
CACHE="$WORK/clang-dl"; OUT="$WORK/clang-$TAG"
mkdir -p "$CACHE"
sums="$CACHE/SHA256SUMS-$TAG"
curl -fsSL -o "$sums" "$base/SHA256SUMS"
# Accept either the current or a future/renamed cross asset prefix.
pkg_name=""
for cand in "mavericks-clang-${LINE}-cross-${TAG}.pkg" "clang-${LINE}-cross-${TAG}.pkg"; do
  awk -v f="$cand" '$2==f {found=1} END{exit !found}' "$sums" && { pkg_name="$cand"; break; }
done
[ -n "$pkg_name" ] || { echo "FATAL: no cross .pkg for $TAG listed in SHA256SUMS" >&2; cat "$sums" >&2; exit 1; }
pkg="$CACHE/$pkg_name"
if [ ! -f "$pkg" ]; then tmp="$pkg.tmp.$$"; curl -fsSL -o "$tmp" "$base/$pkg_name"; mv "$tmp" "$pkg"; fi
want="$(awk -v f="$pkg_name" '$2==f {print $1}' "$sums")"
got="$(shasum -a 256 "$pkg" | awk '{print $1}')"
[ "$want" = "$got" ] || { echo "FATAL: clang pkg sha mismatch: $got != $want" >&2; rm -f "$pkg"; exit 1; }

exp="$CACHE/expanded-$TAG"; rm -rf "$exp"
pkgutil --expand-full "$pkg" "$exp" 1>&2
# The cross toolchain installs at /usr/local/mavericks-clang-<line>-cross; find its bin/clang in the payload.
clangbin="$(find "$exp" -type f -path '*/bin/clang' | head -1)"
[ -n "$clangbin" ] || { echo "FATAL: bin/clang not found in clang pkg payload" >&2; exit 1; }
prefix="$(cd "$(dirname "$clangbin")/.." && pwd)"
rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"; cp -R "$prefix" "$OUT"
[ -x "$OUT/bin/clang" ] && [ -x "$OUT/bin/clang++" ] || { echo "FATAL: extracted clang not executable" >&2; exit 1; }
echo "$OUT"
