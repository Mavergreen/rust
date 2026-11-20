#!/bin/sh
# platform: host-agnostic
#   usage: darwin-xhost-prebuild-test.sh
#          Runs build-native.sh and build-cross.sh as an Apple Silicon Mac would (uname Darwin arm64,
#          mavericks_mode cross), with shipyard's fetches and x.py stubbed, up to x.py, and checks what
#          x.py would get: an aarch64 build triple, no stage0, no Linux-only toml or environment.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
t="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/darwin-xhost.XXXXXX")" && pwd)"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; exit 1; }
V="$(tr -d ' \t\n' < "$ROOT/UPSTREAM_VERSION")"

: "${SHIPYARD_SCRIPTS:?need shipyard}"
mkdir -p "$t/sy" "$t/bin" "$t/c22/bin" "$t/c22/lib" "$t/sdk" "$t/sdk-arm64"
for f in "$SHIPYARD_SCRIPTS"/*; do ln -s "$f" "$t/sy/"; done
ln -s "$SHIPYARD_SCRIPTS/../MavericksToolchain.cmake" "$t/MavericksToolchain.cmake"
stub() { rm -f "$1"; printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }
stub "$t/bin/uname" 'case "$1" in -m) echo arm64 ;; -r) echo 25.0.0 ;; *) echo Darwin ;; esac'
stub "$t/bin/sysctl" 'case "$*" in *hw.optional.arm64*) echo 1 ;; *hw.ncpu*) echo 8 ;; *hw.memsize*) echo 17179869184 ;; *) exit 1 ;; esac'
stub "$t/bin/python3" '{ echo "args=$*"; echo "SDKROOT=${SDKROOT-unset}"
  echo "RUSTFLAGS_X86=${CARGO_TARGET_X86_64_APPLE_DARWIN_RUSTFLAGS-unset}"
  echo "CFLAGS_X86=${CFLAGS_x86_64_apple_darwin-unset}"
  echo "LINUX_HOST_CC=${LINUX_HOST_CC-unset}"; echo "CC=${CC-unset}"
  echo "CFLAGS_ARM64=${CFLAGS_aarch64_apple_darwin-unset}"; echo "CXXFLAGS_ARM64=${CXXFLAGS_aarch64_apple_darwin-unset}"
  echo "TOOLCHAIN_ARM64=${CMAKE_TOOLCHAIN_FILE_aarch64_apple_darwin-unset}"
  echo "CMAKE=$CMAKE"; } > "$CAPTURE"; cp bootstrap.toml "$CAPTURE.toml"; exit 3'
for b in clang clang++ llvm-ar llvm-ranlib llvm-otool llvm-nm llvm-strings llvm-install-name-tool; do stub "$t/c22/bin/$b" 'exit 0'; done
stub "$t/c22/bin/llvm-lipo" 'echo "Non-fat file: $2 is architecture: x86_64"'
stub "$t/sy/mavericks_mode.sh" 'echo cross'
stub "$t/sy/fetch_clang22.sh" "echo '$t/c22'"
stub "$t/sy/fetch_sdk.sh" "case \"\$*\" in *arm64*) echo '$t/sdk-arm64' ;; *) echo '$t/sdk' ;; esac"
stub "$t/sy/fetch_product_pkg.sh" 'mkdir -p "$3/lib" "$3/bin"; : > "$3/lib/librecaulk.a"; printf "#!/bin/sh\n" > "$3/bin/make"; chmod +x "$3/bin/make"; echo "$3"'
stub "$t/sy/fetch_host_libcxx.sh" "touch '$t/host-libcxx-called'; exit 1"
stub "$t/shipyard-cmake" 'exit 0'
mkdir -p "$t/src/rustc-$V-src"; : > "$t/src/rustc-$V-src/x.py"; ( cd "$t/src" && tar -cf "$t/src.tar" "rustc-$V-src" )
rm -f "$t/sy/mavericks_fetch.sh"
cat > "$t/sy/mavericks_fetch.sh" <<EOF
shipyard_curl() { echo 0000; }
shipyard_fetch_verified() { mkdir -p "\$3"; cp "$t/src.tar" "\$3/\$4"; }
EOF

run() {
  CAPTURE="$t/$1.env" PATH="$t/bin:$PATH" SHIPYARD_SCRIPTS="$t/sy" SHIPYARD_CMAKE="$t/shipyard-cmake" \
    MAVERICKS_WORK="$t/work" MAVERICKS_JOBS=2 sh "$ROOT/build/build-$1.sh" > "$t/$1.out" 2>&1 && rc=0 || rc=$?
  [ -f "$t/$1.env" ] || { cat "$t/$1.out"; fail "build-$1.sh never reached x.py on an Apple Silicon Mac (exit $rc)"; }
}
export CAPTURE
for v in native cross; do
  run $v
  e="$t/$v.env"; toml="$t/$v.env.toml"
  grep -qx 'args=x.py install -j 2' "$e" || fail "$v: x.py install -j 2 (got '$(sed -n 1p "$e")')"
  grep -qx 'build = "aarch64-apple-darwin"' "$toml" || fail "$v: an Apple Silicon Mac builds on aarch64-apple-darwin"
  grep -q 'targets = "AArch64;X86"' "$toml" || fail "$v: an arm64-built LLVM keeps AArch64;X86"
  for x in 'rustc = ' local-rebuild use-libcxx compress-debuginfo CMAKE_DISABLE_PRECOMPILE_HEADERS 'x86_64-unknown-linux-gnu'; do
    ! grep -qF "$x" "$toml" || fail "$v: an Apple Silicon build's bootstrap.toml has no '$x' (stage0 and Linux-only settings)"
  done
  for x in SDKROOT=unset RUSTFLAGS_X86=unset CFLAGS_X86=unset LINUX_HOST_CC=unset CC=unset; do
    grep -qx "$x" "$e" || fail "$v: x.py's environment must have $x on an Apple Silicon Mac (got '$(grep "^${x%%=*}=" "$e")')"
  done
  grep -qx "CMAKE=$t/work/work-$v/cmake-bin/cmake" "$e" && [ "$(readlink "$t/work/work-$v/cmake-bin/cmake")" = "$t/shipyard-cmake" ] \
    || fail "$v: cmake on a Mac is shipyard-cmake"
done
grep -q 'host = \["x86_64-apple-darwin"\]' "$t/native.env.toml" || fail "native: hosts x86_64-apple-darwin"
grep -q 'host = \["aarch64-apple-darwin"\]' "$t/cross.env.toml" || fail "cross: hosts aarch64-apple-darwin"
W="$t/work/work-cross"
sed -n '/^\[target\.aarch64-apple-darwin\]$/,/^\[/p' "$t/cross.env.toml" > "$t/cross.arm64"
for l in "cc = \"$W/bin/cc-arm64-pinned\"" "cxx = \"$W/bin/c++-arm64-pinned\"" "linker = \"$W/bin/cc-arm64-pinned\""; do
  grep -qxF "$l" "$t/cross.arm64" || fail "cross: [target.aarch64-apple-darwin] has $l (got '$(cat "$t/cross.arm64")')"
done
for w in cc-arm64-pinned c++-arm64-pinned; do
  grep -q -- '--no-default-config' "$W/bin/$w" && grep -q -- "$W/clang22-" "$W/bin/$w" && ! grep -q /usr/bin/clang "$W/bin/$w" \
    || fail "cross: $w runs the build's clang22 with no cfg, never /usr/bin/clang (got '$(cat "$W/bin/$w")')"
done
for x in CFLAGS_ARM64 CXXFLAGS_ARM64; do
  grep "^$x=" "$t/cross.env" | grep -qF -- '--target=arm64-apple-macos11.0' || fail "cross: $x names --target=arm64-apple-macos11.0"
done
grep -qx "TOOLCHAIN_ARM64=$W/aarch64-11.0.cmake" "$t/cross.env" \
  && grep -qx "include(\"$(cd -P "$t" && pwd)/MavericksToolchain.cmake\")" "$W/aarch64-11.0.cmake" \
  || fail "cross: the arm64 LLVM configures through shipyard's MavericksToolchain.cmake (got '$(cat "$W/aarch64-11.0.cmake" 2>/dev/null)')"
[ ! -e "$t/host-libcxx-called" ] || fail "a Mac build never fetches the Linux host libc++"
[ ! -e "$t/work/work-native/stage0" ] || fail "native cross-hosted from a Mac uses bootstrap's own stage0"
echo "OK darwin-xhost-prebuild-test"
