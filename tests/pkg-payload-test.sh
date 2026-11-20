#!/bin/sh
# platform: host-agnostic
#   usage: [PKG_DIR=DIR] tests/pkg-payload-test.sh
#          Reads every rust and rust-cross pkg in PKG_DIR (default dist/) with stevedore, and the
#          build-info-native.txt beside them. With none there, it packages a fixture native stage with
#          build/package-native-pkg.sh into a scratch PKG_DIR and reads that.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
D="${PKG_DIR:-$ROOT/dist}"
fail() { echo "FAIL $1"; exit 1; }
t="$(mktemp -d "${TMPDIR:-/tmp}/pkgpayload.XXXXXX")"; trap 'rm -rf "$t"' EXIT
REPO_ROOT="$ROOT"; export REPO_ROOT
. "$ROOT/build/lib.sh"
STEVEDORE="$(sh "$SHIPYARD_SCRIPTS/fetch_stevedore.sh")" || fail "no stevedore"
fixture=""
for pkg in "$D"/rust-[0-9]*.pkg "$D"/rust-cross-[0-9]*.pkg; do [ -f "$pkg" ] && break; pkg=""; done
if [ -z "$pkg" ]; then
  fixture=1; D="$t/dist"; W="$t/work"; pfx="$W/work-native/stage/usr/local/mavergreen/rust"
  mkdir -p "$pfx/bin" "$pfx/lib"
  for b in rustc rustc.bin clippy-driver clippy-driver.bin cargo; do printf '#!/bin/sh\n' > "$pfx/bin/$b"; chmod 755 "$pfx/bin/$b"; done
  printf 'x' > "$pfx/bin/._rustc"
  ( MAVERICKS_WORK="$W"; RUST_VARIANT=native; export MAVERICKS_WORK RUST_VARIANT
    . "$ROOT/build/versions.sh"; . "$ROOT/build/lib-rust.sh"
    stage_stamp native > "$WORK/staged.stamp"
    PKG_DIR="$D" MAVERICKS_BUILD_ROOT="$t/build" sh "$ROOT/build/package-native-pkg.sh" ) > "$t/package.log" 2>&1 \
    || { tail -40 "$t/package.log"; fail "build/package-native-pkg.sh could not package the fixture stage"; }
fi
n=0
for pkg in "$D"/rust-[0-9]*.pkg "$D"/rust-cross-[0-9]*.pkg; do
  [ -f "$pkg" ] || continue
  case "$(basename "$pkg")" in rust-cross-*) short=rust-cross ;; *) short=rust ;; esac
  n=$((n+1))
  rm -rf "$t/x" "$t/m"; mkdir -p "$t/m"
  "$STEVEDORE" expand "$pkg" "$t/x" > /dev/null || fail "$short: stevedore cannot expand $pkg"
  first="$(sed -n 's/.*<line choice="\([^"]*\)".*/\1/p' "$t/x/Distribution" | grep -v '^default$' | head -1)"
  [ "$first" = dev.mavergreen.base ] || fail "$short: the first component is '$first', not dev.mavergreen.base"
  comp="$t/x/$short-component.pkg"
  [ -f "$comp/Payload" ] || fail "$short: no $short-component.pkg payload in $pkg"
  gzip -dc "$comp/Payload" | cpio -it 2>/dev/null | sed 's#^\./##' > "$t/list"
  for f in bin/rustc bin/rustc.bin mavergreen.plist; do
    grep -qx "usr/local/mavergreen/$short/$f" "$t/list" || fail "$short: the payload has no usr/local/mavergreen/$short/$f"
  done
  stray="$(grep -e '^\._' -e '/\._' "$t/list" || true)"
  [ -z "$stray" ] || fail "$short: AppleDouble entries in the payload: $stray"
  ( cd "$t/m" && gzip -dc "$comp/Payload" | cpio -id "./usr/local/mavergreen/$short/mavergreen.plist" 2>/dev/null )
  m="$t/m/usr/local/mavergreen/$short/mavergreen.plist"
  [ -f "$m" ] || fail "$short: could not read the manifest"
  i=0; ex=""
  while e="$("$STEVEDORE" plist get "$m" "exports-exclude:$i" 2>/dev/null)"; do ex="$ex $e"; i=$((i+1)); done
  for b in rustc clippy-driver; do
    case " $ex " in *" bin/$b.bin "*) ;; *) fail "$short: manifest must exclude bin/$b.bin from the link farm (bin/$b is its back-fill wrapper)" ;; esac
  done
done
[ "$n" -gt 0 ] || fail "no pkg to read"
bi="$D/build-info-native.txt"
if [ -f "$bi" ]; then
  key() { sed -n "s/^$1=//p" "$bi"; }
  case "$(uname -s)/$(uname -m)" in
    Linux/*) want=x86_64-unknown-linux-gnu ;;
    Darwin/arm64) want=aarch64-apple-darwin ;;
    *) want=x86_64-apple-darwin ;;
  esac
  [ "$(key build-host)" = "$want" ] || fail "build-info-native.txt records build-host='$(key build-host)', not $want"
  for k in build-host-make build-host-libc build-host-cmake; do
    [ -n "$(key "$k")" ] || fail "build-info-native.txt has no $k"
  done
elif [ -n "$fixture" ]; then
  fail "packaging wrote no build-info-native.txt"
fi
echo "OK pkg-payload-test ($n)"
