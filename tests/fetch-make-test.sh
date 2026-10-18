#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"; MAKE_VERSION=4.4.1-mavericks.1
t="$(mktemp -d "${TMPDIR:-/tmp}/fetch-make.XXXXXX")"; trap 'rm -rf "$t"' EXIT
WORK="$t/work"; SHIPYARD_SCRIPTS="$t/sy"
export TARGET_TRIPLE MACOS_MIN REPO_ROOT MAKE_VERSION WORK SHIPYARD_SCRIPTS
. "$ROOT/build/lib-rust.sh"
fail() { echo "FAIL $1"; exit 1; }
mkdir -p "$SHIPYARD_SCRIPTS"
cat > "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" <<'FAKE'
echo "$*" > "$FAKE_ARGS"
mkdir -p "$3/bin"; [ -n "${FAKE_NO_MAKE:-}" ] || { printf '#!/bin/sh\n' > "$3/bin/make"; chmod +x "$3/bin/make"; }
echo "$3"
FAKE
export FAKE_ARGS="$t/args"

b="$(fetch_make)" || fail "fetch_make must succeed when the pkg has bin/make"
[ "$b" = "$WORK/make/bin" ] || fail "fetch_make must print the make product's bin (got '$b')"
[ "$(cat "$t/args")" = "make 4.4.1-mavericks.1 $WORK/make" ] \
  || fail "fetch_make fetches the pinned make through fetch_product_pkg.sh (got '$(cat "$t/args")')"
rm -rf "$WORK"
! FAKE_NO_MAKE=1 fetch_make 2>/dev/null || fail "fetch_make must refuse a make pkg without bin/make"
echo "OK fetch-make-test"
