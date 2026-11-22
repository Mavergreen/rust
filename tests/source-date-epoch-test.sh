#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
fail() { echo "FAIL $1"; exit 1; }
. "$ROOT/build/versions.sh"; . "$ROOT/build/lib-rust.sh"
want="$(git -C "$ROOT" log -1 --format=%ct)"
got="$(unset SOURCE_DATE_EPOCH; cd "$ROOT"; export_source_date_epoch; sh -c 'echo "${SOURCE_DATE_EPOCH:-}"')"
[ "$got" = "$want" ] || fail "with none set, the build exports HEAD's commit time ($want), so OpenSSL's 'built on' date is reproducible: got '$got'"
got="$(SOURCE_DATE_EPOCH=12345; export SOURCE_DATE_EPOCH; export_source_date_epoch; sh -c 'echo "$SOURCE_DATE_EPOCH"')"
[ "$got" = 12345 ] || fail "a SOURCE_DATE_EPOCH already set is kept: got '$got'"
for b in build-native build-cross build-linux; do
  grep -q '^export_source_date_epoch$' "$ROOT/build/$b.sh" || fail "build/$b.sh exports SOURCE_DATE_EPOCH before it builds"
done
echo "PASS source-date-epoch"
