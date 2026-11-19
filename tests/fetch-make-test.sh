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
mkdir -p "$t/darwin"
printf '#!/bin/sh\nif [ "${1:-}" = -s ]; then echo Darwin; else exec %s "$@"; fi\n' "$(command -v uname)" > "$t/darwin/uname"
chmod +x "$t/darwin/uname"

b="$(PATH="$t/darwin:$PATH" fetch_make)" || fail "fetch_make must succeed when the pkg has bin/make"
[ "$b" = "$WORK/make/bin" ] || fail "fetch_make must print the make product's bin (got '$b')"
[ "$(cat "$t/args")" = "make 4.4.1-mavericks.1 $WORK/make" ] \
  || fail "fetch_make fetches the pinned make through fetch_product_pkg.sh (got '$(cat "$t/args")')"
rm -rf "$WORK"
! PATH="$t/darwin:$PATH" FAKE_NO_MAKE=1 fetch_make 2>/dev/null || fail "fetch_make must refuse a make pkg without bin/make"
mkdir -p "$t/linux" "$t/m4" "$t/m3"
printf '#!/bin/sh\nif [ "${1:-}" = -s ]; then echo Linux; else exec %s "$@"; fi\n' "$(command -v uname)" > "$t/linux/uname"
printf '#!/bin/sh\necho "GNU Make 4.4.1"\necho "Built for x86_64-pc-linux-gnu"\n' > "$t/m4/make"
printf '#!/bin/sh\necho "GNU Make 3.81"\n' > "$t/m3/make"
chmod +x "$t/linux/uname" "$t/m4/make" "$t/m3/make"
rm -f "$t/args"
b="$(PATH="$t/linux:$t/m4:$PATH" fetch_make)" || fail "fetch_make on Linux must accept the runner's GNU Make 4"
[ "$b" = "$t/m4" ] || fail "fetch_make on Linux must print the directory of the runner's make (got '$b')"
[ ! -f "$t/args" ] || fail "fetch_make on Linux must not fetch the family's make pkg"
! PATH="$t/linux:$t/m3:$PATH" fetch_make 2>/dev/null || fail "fetch_make on Linux must refuse a make older than GNU Make 4"
echo "OK fetch-make-test"
