#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"; export TARGET_TRIPLE MACOS_MIN REPO_ROOT
t="$(mktemp -d "${TMPDIR:-/tmp}/build-tools.XXXXXX")"; trap 'rm -rf "$t"' EXIT
. "$ROOT/build/lib-rust.sh"
fail() { echo "FAIL $1"; exit 1; }
command -v record_build_tools >/dev/null || fail "lib-rust.sh has no record_build_tools"
mkdir -p "$t/stub"
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$t/stub/$1"; chmod +x "$t/stub/$1"; }
stub uname 'case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) echo "Linux 6.8.0" ;; esac'
stub cmake 'echo "cmake version 3.28.3"; echo; echo "CMake suite maintained by Kitware"'
stub ninja 'echo 1.11.1'
stub make 'echo "GNU Make 4.3"; echo "Built for x86_64-pc-linux-gnu"'
stub python3 'echo "Python 3.12.3"'
stub getconf '[ "$1" = GNU_LIBC_VERSION ] && echo "glibc 2.39"'
echo "keep=me" > "$t/info"
PATH="$t/stub:$PATH" record_build_tools "$t/info"
cat > "$t/want" <<'WANT'
keep=me
build-host=x86_64-unknown-linux-gnu
build-host-cmake=cmake version 3.28.3
build-host-ninja=1.11.1
build-host-make=GNU Make 4.3
build-host-libc=glibc 2.39
build-host-python=Python 3.12.3
WANT
cmp -s "$t/want" "$t/info" || { diff "$t/want" "$t/info" || :; fail "record_build_tools must append the build host's tools, one key per line"; }
rm "$t/stub/ninja"; : > "$t/info2"
mkdir -p "$t/tools"; for c in sed cat; do ln -s "$(command -v $c)" "$t/tools/$c"; done
( PATH="$t/stub:$t/tools"; record_build_tools "$t/info2" )
grep -qx 'build-host-ninja=' "$t/info2" || fail "a tool the host lacks is recorded empty, not as a shell error (got '$(grep ninja "$t/info2")')"
stub uname 'case "$1" in -s) echo Darwin ;; -m) echo x86_64 ;; *) echo "Darwin 13.4.0" ;; esac'
: > "$t/info3"
if ( unset MAKE CMAKE; PATH="$t/stub:$PATH" record_build_tools "$t/info3" ) 2>/dev/null; then
  fail "on a Mac record_build_tools must refuse an unset MAKE or CMAKE (a bare make or cmake there is the Command Line Tools stub)"
fi
mkdir -p "$t/pinned"
printf '#!/bin/sh\necho "GNU Make 4.4.1"\n' > "$t/pinned/make"; printf '#!/bin/sh\necho "cmake version 4.4.5"\n' > "$t/pinned/cmake"
chmod +x "$t/pinned/make" "$t/pinned/cmake"; : > "$t/info3"
( MAKE="$t/pinned/make" CMAKE="$t/pinned/cmake" PATH="$t/stub:$PATH" record_build_tools "$t/info3" ) \
  || fail "record_build_tools refused a Mac with MAKE and CMAKE set"
grep -qx 'build-host=x86_64-apple-darwin' "$t/info3" || fail "a 10.9 build host is x86_64-apple-darwin"
grep -qx 'build-host-make=GNU Make 4.4.1' "$t/info3" || fail "on a Mac build-host-make is \$MAKE's (got '$(grep make "$t/info3")')"
grep -qx 'build-host-cmake=cmake version 4.4.5' "$t/info3" || fail "on a Mac build-host-cmake is \$CMAKE's"
grep -q 'record_build_tools "$NATIVE_STAGE_ROOT/build-tools.txt"' "$ROOT/build/build-native.sh" \
  || fail "build-native.sh records its build tools in \$NATIVE_STAGE_ROOT/build-tools.txt, beside the stage it built"
grep -q 'record_build_tools "$STAGE_ROOT/build-tools.txt"' "$ROOT/build/build-cross.sh" \
  || fail "build-cross.sh records its build tools in \$STAGE_ROOT/build-tools.txt, beside the stage it built"
body="$(sed -n '/^package_variant() {/,/^}/p' "$ROOT/build/package-lib.sh")"
case "$body" in *record_build_tools*|*fetch_make*|*cmake_shim_dir*) fail "packaging re-records build tools: it must read the stage's build-tools.txt" ;; esac
echo "OK build-tools-test"
