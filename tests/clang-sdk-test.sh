#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"; export TARGET_TRIPLE MACOS_MIN REPO_ROOT
. "$ROOT/build/lib-rust.sh"
t="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/clang-sdk.XXXXXX")" && pwd)"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; exit 1; }
mkdir -p "$t/sdk/MacOSX10.9.sdk"; SDK="$t/sdk/MacOSX10.9.sdk"
fresh() { rm -rf "$t/c"; mkdir -p "$t/c/bin"; }
ok_sdks() {
  [ -d "$t/c/SDKs" ] && [ ! -h "$t/c/SDKs" ] || fail "$1: SDKs must end up a real directory"
  [ "$(readlink "$t/c/SDKs/MacOSX10.9.sdk")" = "$SDK" ] || fail "$1: SDKs/MacOSX10.9.sdk must link to the pinned SDK"
}

fresh; ln -s ../sdk109/SDKs "$t/c/SDKs"
populate_clang_sdk "$t/c" "$SDK"; ok_sdks "case 1 clang-22 22.1.8 ships SDKs as a link into Longboat's sdk109, which dangles once the prefix is copied out"

fresh; mkdir -p "$t/elsewhere"; : > "$t/elsewhere/keep"; ln -s "$t/elsewhere" "$t/c/SDKs"
populate_clang_sdk "$t/c" "$SDK"; ok_sdks "case 2 a live SDKs link is replaced too, not written through"
[ -f "$t/elsewhere/keep" ] && [ ! -e "$t/elsewhere/MacOSX10.9.sdk" ] || fail "case 2 the link's target must be left alone"

fresh; mkdir -p "$t/c/SDKs"; : > "$t/c/SDKs/stray"
populate_clang_sdk "$t/c" "$SDK"; ok_sdks "case 3 a real SDKs dir is kept"
[ -f "$t/c/SDKs/stray" ] || fail "case 3 a real SDKs dir's contents are kept"

populate_clang_sdk "$t/c" "$SDK"; ok_sdks "case 4 running it twice"
command -v clang_work_copy >/dev/null || fail "lib-rust.sh has no clang_work_copy"
mkdir -p "$t/fetched/bin" "$t/fetched/lib" "$t/pin"; printf '#!/bin/sh\n' > "$t/fetched/bin/clang"; chmod +x "$t/fetched/bin/clang"
: > "$t/fetched/lib/librecaulk.a"; ln -s ../sdk109/SDKs "$t/fetched/SDKs"; echo 22.1.8-mavericks.99 > "$t/pin/version"
c="$(WORK="$t/work" CLANG_PIN_FILE="$t/pin/version" clang_work_copy "$t/fetched")" || fail "case 5 clang_work_copy must copy the fetched clang22"
[ "$c" = "$t/work/clang22-22.1.8-mavericks.99" ] || fail "case 5 the copy lives in \$WORK/clang22-<pin> (got '$c')"
[ -x "$c/bin/clang" ] && [ -h "$c/SDKs" ] || fail "case 5 the copy keeps executables and links"
echo rust > "$t/recaulk.a"; install_recaulk_into_clang "$t/recaulk.a" "$c"; populate_clang_sdk "$c" "$SDK"
[ ! -s "$t/fetched/lib/librecaulk.a" ] && [ -h "$t/fetched/SDKs" ] \
  || fail "case 5 the build writes Recaulk and the SDK into its copy, never into an installed clang22 or the shared cache"
c2="$(WORK="$t/work" CLANG_PIN_FILE="$t/pin/version" clang_work_copy "$t/fetched")"
[ "$c2" = "$c" ] && [ "$(cat "$c/lib/librecaulk.a")" = rust ] || fail "case 6 a complete copy is reused, not copied again"
echo "OK clang-sdk-test"
