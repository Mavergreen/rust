#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"
export TARGET_TRIPLE MACOS_MIN REPO_ROOT
. "$ROOT/build/lib-rust.sh"
unset MAVERICKS_USE_CCACHE ARM64_CC ARM64_CXX ARM64_LINKER
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
grep -A1 -x '\[rust\]' "$t/onbox/bootstrap.toml" | grep -qx 'deny-warnings = false' \
  || fail "onbox: [rust] deny-warnings = false (bootstrap's own build scripts link at the 10.9 floor, below stage0's 10.12, and stage0 warns)"
hasnt cross 'deny-warnings'
hasnt xhost 'deny-warnings'
for v in cross xhost onbox; do
  has "$v" 'tools = ["cargo", "rustdoc", "clippy", "rustfmt"]'
  hasnt "$v" 'cmake = '
  has "$v" 'cc = "/c/bin/clang"'
  has "$v" 'CMAKE_IGNORE_PREFIX_PATH'
  hasnt "$v" '[target.aarch64-apple-darwin]'
  [ "$(grep -c '^\[target\.x86_64-apple-darwin\]' "$t/$v/bootstrap.toml")" = 1 ] || fail "$v: exactly one x86_64 target section"
  sed -n '/^\[target\.x86_64-apple-darwin\]/,/^\[/p' "$t/$v/bootstrap.toml" \
    | grep -qx 'rustflags = \["-Clink-arg=-mmacosx-version-min=10.9"\]' \
    || fail "$v: x86_64 links must end with the 10.9 floor (stage0 passes 10.12, and clang-22 lets a later version win)"
done

write_x86_cmake_toolchain "$t/tc.cmake" /sdk109 /c
grep -qx 'set(CMAKE_OSX_SYSROOT "/sdk109")' "$t/tc.cmake" || fail "toolchain: sysroot (a cross-hosted x86_64 LLVM must not probe the host SDK)"
grep -qx 'set(CMAKE_OSX_DEPLOYMENT_TARGET "10.9")' "$t/tc.cmake" || fail "toolchain: deployment target"
grep -qx 'set(CMAKE_OSX_ARCHITECTURES "x86_64")' "$t/tc.cmake" || fail "toolchain: arch"
grep -qx 'set(CMAKE_LIBTOOL "/c/bin/llvm-libtool-darwin")' "$t/tc.cmake" \
  || fail "toolchain: LLVM archives with xcrun's libtool when the Command Line Tools are present and llvm-ar when not"
grep -qx 'set(LD64_EXECUTABLE "/c/bin/ld64.lld")' "$t/tc.cmake" \
  || fail "toolchain: LLVM asks xcrun for ld64, which differs with and without the Command Line Tools"
( unset SDKROOT CC CXX; pin_onbox_tools x86_64-apple-darwin /c /sdk109
  [ "$SDKROOT" = /sdk109 ] && [ "$CC" = /c/bin/clang ] && [ "$CXX" = /c/bin/clang++ ] ) \
  || fail "on-box: rustc asks xcrun for an SDK and the cc crate runs cc unless SDKROOT, CC and CXX are set"
( unset SDKROOT CC CXX; pin_onbox_tools aarch64-apple-darwin /c /sdk109
  [ -z "${SDKROOT:-}${CC:-}${CXX:-}" ] ) \
  || fail "cross-hosted: the arm64 build tools must not link against the 10.9 SDK or compile with clang-22"
printf '#!/bin/sh\n' > "$t/fake-shipyard-cmake"; chmod +x "$t/fake-shipyard-cmake"
mkdir -p "$t/dbin"; printf '#!/bin/sh\ncase "$1" in -m) echo arm64 ;; *) echo Darwin ;; esac\n' > "$t/dbin/uname"; chmod +x "$t/dbin/uname"
d="$(PATH="$t/dbin:$PATH"; SHIPYARD_CMAKE="$t/fake-shipyard-cmake" cmake_shim_dir "$t/cmbin")"
[ "$d" = "$t/cmbin" ] || fail "cmake_shim_dir must print its dir (got '$d')"
[ "$(readlink "$t/cmbin/cmake")" = "$t/fake-shipyard-cmake" ] \
  || fail "cmake_shim_dir: bootstrap 1.95 has no [build] cmake key and runs 'cmake' from PATH, so the dir must hold cmake -> shipyard-cmake"
! ( PATH="$t/dbin:$PATH"; SHIPYARD_CMAKE="$t/absent" cmake_shim_dir "$t/cmbin2" ) 2>/dev/null || fail "cmake_shim_dir must refuse a missing shipyard-cmake"
mkdir -p "$t/pinned"
( ARM64_CC=/w/cc-arm64-pinned ARM64_CXX=/w/c++-arm64-pinned ARM64_LINKER=/w/cc-arm64-pinned \
  write_bootstrap_toml "$t/pinned" /usr/local/mavergreen/rust-cross aarch64-apple-darwin aarch64-apple-darwin /c ) || exit 1
arm64_section='cc = "/w/cc-arm64-pinned"
cxx = "/w/c++-arm64-pinned"
ar = "/c/bin/llvm-ar"
ranlib = "/c/bin/llvm-ranlib"
linker = "/w/cc-arm64-pinned"'
[ "$(sed -n '/^\[target\.aarch64-apple-darwin\]$/,/^\[/p' "$t/pinned/bootstrap.toml" | sed '/^\[/d; /^$/d')" = "$arm64_section" ] \
  || fail "ARM64_CC, ARM64_CXX and ARM64_LINKER must become [target.aarch64-apple-darwin] cc, cxx and linker, archived by clang22's llvm-ar (arm64 links record the pinned 11.3 SDK)"
printf 'project(x)\n' > "$t/MavericksToolchain.cmake"
write_arm64_cmake_toolchain "$t/arm.cmake" "$t/MavericksToolchain.cmake" /c
grep -qx 'set(CMAKE_OSX_ARCHITECTURES "arm64")' "$t/arm.cmake" && [ "$(tail -n 1 "$t/arm.cmake")" = "include(\"$t/MavericksToolchain.cmake\")" ] \
  || fail "arm64 toolchain: shipyard's MavericksToolchain.cmake pins the 11.3 SDK and 11.0 floor for arm64 (got '$(cat "$t/arm.cmake")')"
for p in INSTALL_NAME_TOOL=llvm-install-name-tool STRIP=llvm-strip NM=llvm-nm; do
  grep -qx "set(CMAKE_${p%%=*} \"/c/bin/${p#*=}\" CACHE FILEPATH \"clang22's ${p#*=}, which reads Mach-O\")" "$t/arm.cmake" \
    || fail "arm64 toolchain: CMAKE_${p%%=*} is clang22's ${p#*=} on every host (the compiler is a wrapper, so MavericksToolchain.cmake finds no tools beside it, and a Linux PATH's are GNU's; got '$(cat "$t/arm.cmake")')"
done
! write_arm64_cmake_toolchain "$t/arm2.cmake" "$t/absent.cmake" /c 2>/dev/null || fail "arm64 toolchain: a missing MavericksToolchain.cmake must be refused"
mkdir -p "$t/fc/bin"
for d in clang clang++; do printf '#!/bin/sh\nprintf "%%s\\n" "$0" "$@"\n' > "$t/fc/bin/$d"; chmod +x "$t/fc/bin/$d"; done
write_pinned_cc "$t/pcc" /sdk113 "$t/fc"
write_pinned_cc "$t/pcxx" /sdk113 "$t/fc" clang++
[ -x "$t/pcc" ] && [ -x "$t/pcxx" ] || fail "arm64 linker is clang22: write_pinned_cc must write executable wrappers"
! grep -q /usr/bin/clang "$t/pcc" "$t/pcxx" || fail "arm64 linker is clang22: the wrappers must never name /usr/bin/clang"
"$t/pcc" -arch arm64 -isysroot /sdk109 -o out in.o > "$t/pcc.link"
"$t/pcxx" -c -isysroot /sdk109 -o out.o in.cpp > "$t/pcxx.compile"
[ "$(sed -n 1p "$t/pcc.link")" = "$t/fc/bin/clang" ] || fail "arm64 linker is clang22: cc-arm64-pinned must exec \$CLANGDIR/bin/clang (got '$(sed -n 1p "$t/pcc.link")')"
[ "$(sed -n 1p "$t/pcxx.compile")" = "$t/fc/bin/clang++" ] || fail "arm64 c++ is clang22: c++-arm64-pinned must exec \$CLANGDIR/bin/clang++"
for f in --no-default-config --target=arm64-apple-macos11.0 -fuse-ld=lld; do
  grep -qx -- "$f" "$t/pcc.link" || fail "arm64 linker is clang22: cc-arm64-pinned must pass $f"
done
[ "$(awk 'p { s = $0; p = 0 } $0 == "-isysroot" { p = 1 } END { print s }' "$t/pcc.link")" = /sdk113 ] \
  || fail "arm64 linker is clang22: the last -isysroot must be the 11.3 SDK (rustc passes \$SDKROOT's, the 10.9 SDK on Linux, or xcrun's)"
for f in --no-default-config --target=arm64-apple-macos11.0; do
  grep -qx -- "$f" "$t/pcxx.compile" || fail "arm64 c++ is clang22: c++-arm64-pinned must pass $f"
done
[ "$(awk 'p { s = $0; p = 0 } $0 == "-isysroot" { p = 1 } END { print s }' "$t/pcxx.compile")" = /sdk113 ] \
  || fail "arm64 c++ is clang22: a compile's last -isysroot must be the 11.3 SDK"
grep -qx -- -nostdinc++ "$t/pcxx.compile" && [ "$(awk 'p { s = $0; p = 0 } $0 == "-isystem" { p = 1 } END { print s }' "$t/pcxx.compile")" = /sdk113/usr/include/c++/v1 ] \
  || fail "arm64 c++ is clang22: C++ compiles read the 11.3 SDK's libc++ headers, which match the libc++ arm64 links against (clang22's own are libc++ 22's: __libcpp_verbose_abort, __hash_memory)"
! grep -q -- -nostdinc++ "$t/pcc.link" || fail "arm64 linker is clang22: the C driver, rustc's linker, gets no C++ header flags"
! grep -qx -- -fuse-ld=lld "$t/pcxx.compile" \
  || fail "arm64 c++ is clang22: a compile gets no -fuse-ld (CMake's flag checks read the unused-argument warning as a missing flag)"
mkdir -p "$t/cc"
MAVERICKS_USE_CCACHE=1 write_bootstrap_toml "$t/cc" /p aarch64-apple-darwin aarch64-apple-darwin /c
grep -qx 'ccache = true' "$t/cc/bootstrap.toml" || fail "MAVERICKS_USE_CCACHE=1 must set [build] ccache = true (LLVM is most of a cold CI build)"
hasnt cross 'ccache'

py="$(command -v python3 || echo /opt/pkg/bin/python3)"
golden() {
  sed "s#^python = \"$py\"\$#python = \"@PYTHON@\"#" "$t/$1/bootstrap.toml" | cmp -s - "$ROOT/tests/fixtures/bootstrap/$2.toml" \
    || { sed "s#^python = \"$py\"\$#python = \"@PYTHON@\"#" "$t/$1/bootstrap.toml" | diff "$ROOT/tests/fixtures/bootstrap/$2.toml" - || :
         fail "$1: today's Darwin build hosts must write tests/fixtures/bootstrap/$2.toml byte for byte"; }
}
golden cross cross; golden xhost xhost; golden onbox onbox; golden pinned pinned

L=x86_64-unknown-linux-gnu
section() { sed -n "/^\\[target\\.$2\\]\$/,/^\\[/p" "$t/$1/bootstrap.toml" | sed '/^\[/d; /^$/d'; }
mkdir -p "$t/lnative" "$t/lcross" "$t/ltar" "$t/lnocc"
LINUX_HOST_CC=/w/linux-host/cc LINUX_HOST_CXX=/w/linux-host/c++ \
  write_bootstrap_toml "$t/lnative" /usr/local/mavergreen/rust $L x86_64-apple-darwin /c /s0
( LINUX_HOST_CC=/w/linux-host/cc LINUX_HOST_CXX=/w/linux-host/c++ \
  ARM64_CC=/w/cc-arm64-pinned ARM64_CXX=/w/c++-arm64-pinned ARM64_LINKER=/w/cc-arm64-pinned \
  write_bootstrap_toml "$t/lcross" /usr/local/mavergreen/rust-cross $L aarch64-apple-darwin /c /s0 ) || exit 1
LINUX_HOST_CC=/w/linux-host/cc LINUX_HOST_CXX=/w/linux-host/c++ \
  write_bootstrap_toml "$t/ltar" /opt/mavergreen/rust $L $L /c /s0
has lnative 'build = "x86_64-unknown-linux-gnu"'
has lnative 'host = ["x86_64-apple-darwin"]'
has lnative 'target = ["x86_64-apple-darwin"]'
has lnative 'targets = "X86"'
has lnative 'local-rebuild = true'
hasnt lnative 'deny-warnings = false'
has lcross 'host = ["aarch64-apple-darwin"]'
has lcross 'target = ["aarch64-apple-darwin", "x86_64-apple-darwin"]'
has lcross 'targets = "AArch64;X86"'
[ "$(section lcross aarch64-apple-darwin)" = "$arm64_section" ] \
  || fail "lcross: [target.aarch64-apple-darwin] compiles and links with \$ARM64_CC, \$ARM64_CXX and \$ARM64_LINKER (got '$(section lcross aarch64-apple-darwin)')"
has ltar 'host = ["x86_64-unknown-linux-gnu"]'
has ltar 'target = ["x86_64-unknown-linux-gnu", "x86_64-apple-darwin"]'
has ltar 'targets = "X86"'
mkdir -p "$t/ltar64"
( LINUX_HOST_CC=/w/linux-host/cc LINUX_HOST_CXX=/w/linux-host/c++ \
  ARM64_CC=/w/cc-arm64-pinned ARM64_CXX=/w/c++-arm64-pinned ARM64_LINKER=/w/cc-arm64-pinned \
  write_bootstrap_toml "$t/ltar64" /opt/mavergreen/rust $L $L /c /s0 ) || exit 1
has ltar64 'host = ["x86_64-unknown-linux-gnu"]'
has ltar64 'target = ["x86_64-unknown-linux-gnu", "x86_64-apple-darwin", "aarch64-apple-darwin"]'
has ltar64 'targets = "AArch64;X86"'
[ "$(section ltar64 aarch64-apple-darwin)" = "$arm64_section" ] \
  || fail "ltar64: the Linux tarball's [target.aarch64-apple-darwin] compiles and links with \$ARM64_CC, \$ARM64_CXX and \$ARM64_LINKER (got '$(section ltar64 aarch64-apple-darwin)')"
want='cc = "/w/linux-host/cc"
cxx = "/w/linux-host/c++"
ar = "/c/bin/llvm-ar"
ranlib = "/c/bin/llvm-ranlib"
linker = "/w/linux-host/c++"'
for v in lnative lcross ltar; do
  [ "$(grep -c "^\\[target\\.$L\\]\$" "$t/$v/bootstrap.toml")" = 1 ] || fail "$v: exactly one [target.$L] section"
  [ "$(section $v $L)" = "$want" ] \
    || fail "$v: [target.$L] compiles and links the build triple with clang22 for Linux (D4) and its llvm-ar and llvm-ranlib (got '$(section $v $L)')"
  sed -n '/^\[target\.x86_64-apple-darwin\]/,/^\[/p' "$t/$v/bootstrap.toml" | grep -qx 'cc = "/c/bin/clang"' \
    || fail "$v: the Darwin target still compiles with clang22's clang.cfg"
done
for v in cross xhost onbox pinned; do hasnt "$v" "[target.$L]"; done
if ( unset LINUX_HOST_CC LINUX_HOST_CXX; write_bootstrap_toml "$t/lnocc" /p $L x86_64-apple-darwin /c ) 2> "$t/lnocc.err"; then
  fail "a Linux build triple with no LINUX_HOST_CC/LINUX_HOST_CXX must fail, not write an empty compiler"
fi
grep -q LINUX_HOST_CC "$t/lnocc.err" || fail "the failure must name LINUX_HOST_CC"
for v in lnative lcross ltar; do
  sed -n '/^\[llvm\]$/,/^\[/p' "$t/$v/bootstrap.toml" | grep -qx 'use-libcxx = true' \
    || fail "$v: [llvm] use-libcxx = true, or rustc_llvm links the build triple's LLVM with the runner's libstdc++"
done
for v in cross xhost onbox pinned; do hasnt "$v" 'use-libcxx'; done
for v in lnative lcross ltar; do
  sed -n '/^\[rust\]$/,/^\[/p' "$t/$v/bootstrap.toml" | grep -qx 'compress-debuginfo = "off"' \
    || fail "$v: [rust] compress-debuginfo = \"off\" (the source tarball's dist profile says zlib, and clang22's ld.lld has no zlib)"
done
for v in cross xhost onbox pinned; do hasnt "$v" 'compress-debuginfo'; done
for v in lnative lcross ltar; do
  grep '^build-config = ' "$t/$v/bootstrap.toml" | grep -qF ', CMAKE_DISABLE_PRECOMPILE_HEADERS = "ON" }' \
    || fail "$v: LLVM's build-config disables precompiled headers (ccache, which bootstrap runs as the compiler launcher, refuses LLVM 22's PCH: 93% uncacheable)"
done
for v in cross xhost onbox pinned; do hasnt "$v" 'CMAKE_DISABLE_PRECOMPILE_HEADERS'; done
sdkvars() { printf '%s|%s|%s|%s' "${SDKROOT:-}" "${CARGO_TARGET_X86_64_APPLE_DARWIN_RUSTFLAGS:-}" \
  "${CFLAGS_x86_64_apple_darwin:-}" "${CXXFLAGS_x86_64_apple_darwin:-}"; }
got="$( unset SDKROOT CARGO_TARGET_X86_64_APPLE_DARWIN_RUSTFLAGS CFLAGS_x86_64_apple_darwin CXXFLAGS_x86_64_apple_darwin
  pin_linux_build_sdk $L /sdk109 && sdkvars )"
[ "$got" = "/sdk109||-isysroot /sdk109 -mmacosx-version-min=10.9|-isysroot /sdk109 -mmacosx-version-min=10.9" ] \
  || fail "a Linux build: rustc's Apple links read SDKROOT (else they run xcrun), the target's compiles name the 10.9 SDK, and no target rustflags carry a host path (cargo hashes them into every crate's metadata) (got '$got')"
( unset SDKROOT CARGO_TARGET_X86_64_APPLE_DARWIN_RUSTFLAGS CFLAGS_x86_64_apple_darwin CXXFLAGS_x86_64_apple_darwin
  env | grep -q '^SDKROOT=' && exit 1
  pin_linux_build_sdk $L /sdk109; env | grep -q '^CXXFLAGS_x86_64_apple_darwin=' ) \
  || fail "pin_linux_build_sdk must export what it sets"
for b in aarch64-apple-darwin x86_64-apple-darwin; do
  got="$( unset SDKROOT CARGO_TARGET_X86_64_APPLE_DARWIN_RUSTFLAGS CFLAGS_x86_64_apple_darwin CXXFLAGS_x86_64_apple_darwin
    pin_linux_build_sdk $b /sdk109 && sdkvars )"
  [ "$got" = '|||' ] || fail "build $b: pin_linux_build_sdk is for a Linux build triple only (got '$got')"
done
! pin_linux_build_sdk $L '/s d k' 2>/dev/null || fail "an SDK path with a space must be refused: cc-rs splits CFLAGS on spaces"
mkdir -p "$t/ubin" "$t/rcm"
printf '#!/bin/sh\ncase "$1" in -m) echo x86_64 ;; *) echo Linux ;; esac\n' > "$t/ubin/uname"
printf '#!/bin/sh\n' > "$t/rcm/cmake"; chmod +x "$t/ubin/uname" "$t/rcm/cmake"
d="$(PATH="$t/ubin:$t/rcm:$PATH" SHIPYARD_CMAKE="$t/fake-shipyard-cmake" cmake_shim_dir "$t/lcmbin")"
[ "$d" = "$t/lcmbin" ] && [ "$(readlink "$t/lcmbin/cmake")" = "$t/rcm/cmake" ] \
  || fail "on Linux cmake_shim_dir links the runner's cmake (shipyard-cmake is a Mac pkg; got '$(readlink "$t/lcmbin/cmake")')"
mkdir -p "$t/tools"; ln -s "$(command -v mkdir)" "$(command -v ln)" "$t/tools/"
! ( PATH="$t/ubin:$t/tools"; cmake_shim_dir "$t/lcmbin2" ) 2>/dev/null || fail "on Linux cmake_shim_dir must refuse a PATH with no cmake"
( unset SDKROOT CC CXX; pin_onbox_tools $L /c /sdk109
  [ -z "${SDKROOT:-}${CC:-}${CXX:-}" ] ) \
  || fail "a Linux build: the cc crate must not hand the 10.9 SDK or clang22's clang.cfg to x86_64-unknown-linux-gnu build scripts"
echo "OK bootstrap-toml-test"
