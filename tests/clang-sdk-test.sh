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
echo "OK clang-sdk-test"
