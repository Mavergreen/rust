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
  package_fixture() {
    ( MAVERICKS_WORK="$W"; RUST_VARIANT=native; export MAVERICKS_WORK RUST_VARIANT
      . "$ROOT/build/versions.sh"; . "$ROOT/build/lib-rust.sh"
      stage_stamp native > "$WORK/staged.stamp"
      PKG_DIR="$D" MAVERICKS_BUILD_ROOT="$t/build" sh "$ROOT/build/package-native-pkg.sh" ) > "$t/package.log" 2>&1
  }
  if package_fixture; then fail "packaging a stage with no build-tools.txt must fail, not record this host's tools"; fi
  rm -rf "$D"
  printf '%s\n' build-host=x86_64-unknown-linux-gnu 'build-host-cmake=cmake version 3.28.3' build-host-ninja=1.11.1 \
    'build-host-make=GNU Make 4.3' 'build-host-libc=glibc 2.39' 'build-host-python=Python 3.12.3' > "$W/work-native/stage/build-tools.txt"
  package_fixture || { tail -40 "$t/package.log"; fail "build/package-native-pkg.sh could not package the fixture stage"; }
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
for v in native cross; do
  bi="$D/build-info-$v.txt"
  case "$v" in native) p="$D"/rust-[0-9]*.pkg ;; cross) p="$D"/rust-cross-[0-9]*.pkg ;; esac
  for f in $p; do [ ! -f "$f" ] || [ -f "$bi" ] || fail "$(basename "$f") has no build-info-$v.txt beside it"; done
  [ -f "$bi" ] || continue
  key() { sed -n "s/^$1=//p" "$bi"; }
  case "$(key build-host)" in
    x86_64-unknown-linux-gnu|aarch64-apple-darwin|x86_64-apple-darwin) ;;
    *) fail "build-info-$v.txt records build-host='$(key build-host)', not a known build triple" ;;
  esac
  for k in build-host-make build-host-libc build-host-cmake; do
    [ -n "$(key "$k")" ] || fail "build-info-$v.txt has no $k"
  done
  if [ -n "$fixture" ]; then sr="$W/work-$v/stage"; else sr="$(MAVERICKS_WORK="${MAVERICKS_WORK:-}" RUST_VARIANT=$v sh -c '. "$1/build/versions.sh"; printf "%s\n" "$WORK/stage"' sh "$ROOT")"; fi
  [ -f "$sr/build-tools.txt" ] || continue
  while IFS= read -r kv; do
    k="${kv%%=*}"; want="$(printf '%s' "${kv#*=}" | tr -s '[:space:]' '_')"
    [ "$(key "$k")" = "$want" ] || fail "build-info-$v.txt records $k='$(key "$k")', not the stage's '$want' ($sr/build-tools.txt)"
  done < "$sr/build-tools.txt"
done
if [ -n "$fixture" ]; then
  bi="$D/build-info-native.txt"
  [ -f "$bi" ] || fail "packaging wrote no build-info-native.txt"
  [ "$(sed -n 's/^build-host=//p' "$bi")" = x86_64-unknown-linux-gnu ] \
    || fail "build-info records build-host='$(sed -n 's/^build-host=//p' "$bi")', not the Linux host the stage records"
  [ -n "$(sed -n 's/^build-host-make=//p' "$bi")" ] && [ -n "$(sed -n 's/^build-host-libc=//p' "$bi")" ] \
    || fail "a Linux-built stage's build-info has an empty build-host-make or build-host-libc"
fi
echo "OK pkg-payload-test ($n)"
