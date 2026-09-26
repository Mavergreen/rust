#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"
export TARGET_TRIPLE MACOS_MIN REPO_ROOT
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
  hasnt "$v" 'cmake = '
  has "$v" 'cc = "/c/bin/clang"'
  has "$v" 'CMAKE_IGNORE_PREFIX_PATH'
  hasnt "$v" '[target.aarch64-apple-darwin]'
  [ "$(grep -c '^\[target\.x86_64-apple-darwin\]' "$t/$v/bootstrap.toml")" = 1 ] || fail "$v: exactly one x86_64 target section"
done

write_x86_cmake_toolchain "$t/tc.cmake" /sdk109
grep -qx 'set(CMAKE_OSX_SYSROOT "/sdk109")' "$t/tc.cmake" || fail "toolchain: sysroot (a cross-hosted x86_64 LLVM must not probe the host SDK)"
grep -qx 'set(CMAKE_OSX_DEPLOYMENT_TARGET "10.9")' "$t/tc.cmake" || fail "toolchain: deployment target"
grep -qx 'set(CMAKE_OSX_ARCHITECTURES "x86_64")' "$t/tc.cmake" || fail "toolchain: arch"
printf '#!/bin/sh\n' > "$t/fake-shipyard-cmake"; chmod +x "$t/fake-shipyard-cmake"
d="$(SHIPYARD_CMAKE="$t/fake-shipyard-cmake" cmake_shim_dir "$t/cmbin")"
[ "$d" = "$t/cmbin" ] || fail "cmake_shim_dir must print its dir (got '$d')"
[ "$(readlink "$t/cmbin/cmake")" = "$t/fake-shipyard-cmake" ] \
  || fail "cmake_shim_dir: bootstrap 1.95 has no [build] cmake key and runs 'cmake' from PATH, so the dir must hold cmake -> shipyard-cmake"
! SHIPYARD_CMAKE="$t/absent" cmake_shim_dir "$t/cmbin2" 2>/dev/null || fail "cmake_shim_dir must refuse a missing shipyard-cmake"
mkdir -p "$t/pinned"
ARM64_LINKER=/w/cc-arm64-pinned write_bootstrap_toml "$t/pinned" /usr/local/mavergreen/rust-cross aarch64-apple-darwin aarch64-apple-darwin /c
grep -A1 -x '\[target.aarch64-apple-darwin\]' "$t/pinned/bootstrap.toml" | grep -qx 'linker = "/w/cc-arm64-pinned"' \
  || fail "ARM64_LINKER must become [target.aarch64-apple-darwin] linker (arm64 links record the pinned 11.3 SDK)"
write_cmake_toolchain "$t/arm.cmake" /sdk113 11.0 arm64
grep -qx 'set(CMAKE_OSX_SYSROOT "/sdk113")' "$t/arm.cmake" && grep -qx 'set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")' "$t/arm.cmake" \
  && grep -qx 'set(CMAKE_OSX_ARCHITECTURES "arm64")' "$t/arm.cmake" \
  || fail "arm64 toolchain: the aarch64 LLVM tools shipped minos 27.0 without one"
write_pinned_cc "$t/pcc" /sdk113
[ -x "$t/pcc" ] && grep -q 'exec /usr/bin/clang -isysroot "/sdk113" "\$@"' "$t/pcc" || fail "pinned cc wrapper"
mkdir -p "$t/cc"
MAVERICKS_USE_CCACHE=1 write_bootstrap_toml "$t/cc" /p aarch64-apple-darwin aarch64-apple-darwin /c
grep -qx 'ccache = true' "$t/cc/bootstrap.toml" || fail "MAVERICKS_USE_CCACHE=1 must set [build] ccache = true (LLVM is most of a cold CI build)"
hasnt cross 'ccache'
echo "OK bootstrap-toml-test"
