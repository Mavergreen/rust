#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"; export TARGET_TRIPLE MACOS_MIN REPO_ROOT
. "$ROOT/build/lib-rust.sh"
fail() { echo "FAIL $1"; exit 1; }
chk() { got="$(loader_rel /p "$1")"; [ "$got" = "$2" ] || fail "loader_rel /p $1: got '$got', want '$2' (the rpath from a file's dir back to <prefix>/lib, computed without python3)"; }
chk /p/bin/rustc.bin @loader_path/../lib
chk /p/lib/librustc_driver-0123456789abcdef.dylib @loader_path
chk /p/lib/rustlib/x86_64-apple-darwin/bin/llc @loader_path/../../..
chk /p/lib/rustlib/x86_64-apple-darwin/lib/libstd-0123456789abcdef.dylib @loader_path/../../..
echo "OK loader-rel-test"
