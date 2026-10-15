#!/bin/sh
# platform: macOS-only -- shipyard's fetch_product_pkg.sh expands the pkg with pkgutil
#   usage: fetch-clang.sh     prints the extracted clang-22 prefix (holds bin/clang);
#          CLANG_VARIANT=cross|native picks the pkg; re-verified against SHA256SUMS every run
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"
. "$HERE/msc.sh"
KIND="${CLANG_VARIANT:-cross}"
TAG="$(tr -d ' \t\n' < "$CLANG_PIN_FILE")"
[ -n "$TAG" ] || { echo "FATAL: empty components/clang/version" >&2; exit 1; }
LINE="${TAG%%.*}"                                  # 22 from 22.1.1-mavericks.1
case "$KIND" in
  native) short="clang$LINE" ;;
  cross) short="clang$LINE-cross" ;;
  *) echo "FATAL: CLANG_VARIANT must be cross or native, not '$KIND'" >&2; exit 1 ;;
esac
OUT="$WORK/clang-$KIND-$TAG"
sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" --asset "mavericks-clang-$LINE-$KIND-$TAG.pkg" "$short" "$TAG" "$OUT" >/dev/null
[ -x "$OUT/bin/clang" ] && [ -x "$OUT/bin/clang++" ] || { echo "FATAL: extracted clang not executable" >&2; exit 1; }
echo "$OUT"
