#!/bin/sh
# platform: macOS-only -- pkgutil and lsbom read the package
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
D="${PKG_DIR:-$ROOT/dist}"
fail() { echo "FAIL $1"; exit 1; }
n=0
t="$(mktemp -d "${TMPDIR:-/tmp}/pkgpayload.XXXXXX")"; trap 'rm -rf "$t"' EXIT
for pkg in "$D"/rust-[0-9]*.pkg "$D"/rust-cross-[0-9]*.pkg; do
  [ -f "$pkg" ] || continue
  case "$(basename "$pkg")" in rust-cross-*) short=rust-cross ;; *) short=rust ;; esac
  n=$((n+1))
  rm -rf "$t/x" "$t/f" "$t/list"
  pkgutil --expand "$pkg" "$t/x"
  boms="$(find "$t/x" -name Bom)"
  [ -n "$boms" ] || fail "$short: no component Bom in $pkg"
  # platform: pkgbuild stores each file's xattrs (on a modern Mac, the undeletable
  #           com.apple.provenance) as a ._X member beside X; only a ._X with no X is a stray file
  for b in $boms; do
    lsbom -s "$b" > "$t/list"
    stray="$(grep '/\._[^/]*$' "$t/list" | while IFS= read -r a; do
      grep -qxF "$(dirname "$a")/$(basename "$a" | sed 's/^\._//')" "$t/list" || printf '%s\n' "$a"; done)"
    [ -z "$stray" ] || fail "$short: stray AppleDouble file(s) in $(basename "$(dirname "$b")"): $stray"
  done
  pkgutil --expand-full "$pkg" "$t/f" >/dev/null
  files="$(find "$t/f" -path '*/Payload/*' | sed "s#^$t/f/[^/]*/Payload/##")"
  printf '%s\n' "$files" | grep -qx "usr/local/mavergreen/$short/mavergreen.plist" || fail "$short: no manifest"
  printf '%s\n' "$files" | grep -qx "usr/local/mavergreen/$short/bin/rustc.bin" || fail "$short: rustc.bin missing"
  ex="$(/usr/libexec/PlistBuddy -c 'Print :exports-exclude' "$(find "$t/f" -path "*/Payload/usr/local/mavergreen/$short/mavergreen.plist")")"
  for b in rustc clippy-driver; do
    printf '%s\n' "$ex" | grep -q "bin/$b.bin" || fail "$short: manifest must exclude bin/$b.bin from the link farm (bin/$b is its back-fill wrapper)"
  done
done
[ "$n" -gt 0 ] || { echo "no pkg built -- skipping"; exit 77; }
echo "OK pkg-payload-test ($n)"
