#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"
export TARGET_TRIPLE MACOS_MIN REPO_ROOT
SHIPYARD_CMAKE=/opt/fake/bin/shipyard-cmake; export SHIPYARD_CMAKE
. "$ROOT/build/lib-rust.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-toml.XXXXXX")"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; exit 1; }
has() { grep -qF -- "$2" "$t/$1/bootstrap.toml" || fail "$1: missing '$2'"; }
hasnt() { ! grep -qF -- "$2" "$t/$1/bootstrap.toml" || fail "$1: must not contain '$2'"; }

mkdir -p "$t/cross" "$t/xhost" "$t/onbox"
write_bootstrap_toml "$t/cross" /usr/local/mavergreen/rust-cross aarch64-apple-darwin aarch64-apple-darwin /c
write_bootstrap_toml "$t/xhost" /usr/local/mavergreen/rust aarch64-apple-darwin x86_64-apple-darwin /c
write_bootstrap_toml "$t/onbox" /usr/local/mavergreen/rust x86_64-apple-darwin x86_64-apple-darwin /c /s0

has cross 'build = "aarch64-apple-darwin"'
has cross 'host = ["aarch64-apple-darwin"]'
has cross 'target = ["aarch64-apple-darwin", "x86_64-apple-darwin"]'
has cross 'targets = "AArch64;X86"'
has xhost 'build = "aarch64-apple-darwin"'
has xhost 'host = ["x86_64-apple-darwin"]'
has xhost 'target = ["x86_64-apple-darwin"]'
has xhost 'targets = "AArch64;X86"'
has onbox 'build = "x86_64-apple-darwin"'
has onbox 'targets = "X86"'
has onbox 'rustc = "/s0/bin/rustc"'
has onbox 'local-rebuild = true'
hasnt xhost 'local-rebuild'
hasnt cross 'rustc = '
for v in cross xhost onbox; do
  has "$v" 'tools = ["cargo", "rustdoc", "clippy", "rustfmt"]'
  has "$v" 'cmake = "/opt/fake/bin/shipyard-cmake"'
  has "$v" 'cc = "/c/bin/clang"'
  has "$v" 'CMAKE_IGNORE_PREFIX_PATH'
  hasnt "$v" '[target.aarch64-apple-darwin]'
  [ "$(grep -c '^\[target\.x86_64-apple-darwin\]' "$t/$v/bootstrap.toml")" = 1 ] || fail "$v: exactly one x86_64 target section"
done

write_x86_cmake_toolchain "$t/tc.cmake" /sdk109
grep -qx 'set(CMAKE_OSX_SYSROOT "/sdk109")' "$t/tc.cmake" || fail "toolchain: sysroot (a cross-hosted x86_64 LLVM must not probe the host SDK)"
grep -qx 'set(CMAKE_OSX_DEPLOYMENT_TARGET "10.9")' "$t/tc.cmake" || fail "toolchain: deployment target"
grep -qx 'set(CMAKE_OSX_ARCHITECTURES "x86_64")' "$t/tc.cmake" || fail "toolchain: arch"
echo "OK bootstrap-toml-test"
