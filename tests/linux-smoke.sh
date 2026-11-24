#!/bin/sh
# platform: host-agnostic
#   usage: linux-smoke.sh [TARBALL [PROBE]]
#          The smoke of the Linux-hosted tarball (rust-<v>-linux-x86_64.tar.gz). Its static half runs
#          on any host: fixture Mach-O and ELF files, a good one of each passing and each bad one
#          failing, show what the two audits refuse. The executing half runs on Linux only. It unpacks
#          TARBALL as shipyard's fetch_product_tar.sh does, then checks the three things below.
#            - The shipped ELF loads only glibc, libgcc_s and its own libraries.
#            - rustc -vV names the Linux host and the pinned release.
#            - mavergreen.plist is rust's, at the tarball's version.
#            - target/target-core2.sh passes with its rustc: 10.9 and core2 by default.
#            - cargo builds a HashMap+Instant program for x86_64-apple-darwin, linked by clang22's
#              clang++ against the pinned 10.9 SDK, and the output is thin x86_64 with minos 10.9,
#              sdk 10.9, Recaulk's _clock_gettime, and no /opt/ load path.
#            - the arm64 std is thin arm64 at minos 11.0 and sdk 11.3, with no librecaulk.a, and cargo
#              builds the same program for aarch64-apple-darwin with clang22 (no cfg) and the 11.3 SDK.
#            - a host-target hello builds and runs.
#          TARBALL defaults to the one dist/ holds. Naming one makes its absence a failure. Without
#          one, and with none in dist/, it ends after the static half; off Linux it ends there too.
#          PROBE is where the 10.9 program is copied, for release.yml's vm-test to run on 10.9; it
#          prints "smoke Some(109) true".
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/build/versions.sh"; . "$ROOT/build/lib-rust.sh"; . "$ROOT/tests/lib/clang22.sh"; macho_tools
t="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/linux-smoke.XXXXXX")" && pwd)"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; exit 1; }

minos_sdk() {
  "$OTOOL" -l "$1" | awk '$1 == "cmd" { v = ($2 == "LC_VERSION_MIN_MACOSX"); b = ($2 == "LC_BUILD_VERSION") }
    (v && $1 == "version") || (b && $1 == "minos") { m = $2 } (v || b) && $1 == "sdk" { s = $2 } END { print m " " s }'
}
audit_macho() {
  "$LIPO" -info "$1" | grep -Eq 'architecture: x86_64 *$' || { echo "$2 is not thin x86_64"; return 1; }
  _v="$(minos_sdk "$1")"
  [ "$_v" = "10.9 10.9" ] || { echo "$2 records minos and sdk '$_v', not '10.9 10.9'"; return 1; }
  "$NM" --defined-only "$1" | awk '$3 == "_clock_gettime" { f = 1 } END { exit !f }' \
    || { echo "$2 does not define _clock_gettime: 10.9's libSystem has none, so Recaulk's was not linked"; return 1; }
  _p="$( { "$OTOOL" -L "$1" | tail -n +2 | awk '{ print $1 }'
           "$OTOOL" -l "$1" | awk '/LC_RPATH/ { r = 1 } r && / path / { print $2; r = 0 }'; } | grep '^/opt/' | sed -n 1p)" || _p=""
  [ -z "$_p" ] || { echo "$2 loads $_p"; return 1; }
}

audit_arm64() {
  "$LIPO" -info "$1" | grep -Eq 'architecture: arm64 *$' || { echo "$2 is not thin arm64"; return 1; }
  _v="$(minos_sdk "$1")"
  [ "$_v" = "11.0 11.3" ] || { echo "$2 records minos and sdk '$_v', not '11.0 11.3'"; return 1; }
  _p="$( { "$OTOOL" -L "$1" | tail -n +2 | awk '{ print $1 }'
           "$OTOOL" -l "$1" | awk '/LC_RPATH/ { r = 1 } r && / path / { print $2; r = 0 }'; } | grep '^/opt/' | sed -n 1p)" || _p=""
  [ -z "$_p" ] || { echo "$2 loads $_p"; return 1; }
}

printf 'int clock_gettime(int c, void *s) { (void)c; (void)s; return 0; }\nint main(void) { return 0; }\n' > "$t/cg.c"
printf 'int main(void) { return 0; }\n' > "$t/main.c"
fixture_cc -o "$t/good" "$t/cg.c"
audit_macho "$t/good" good > "$t/out" || { cat "$t/out"; fail "a 10.9 x86_64 fixture with _clock_gettime must pass the Mach-O audit"; }
bad_macho() {
  if audit_macho "$t/bad" bad > "$t/out"; then fail "the Mach-O audit passed a fixture it must refuse: $1"; fi
  grep -q "$2" "$t/out" || { cat "$t/out"; fail "the refusal must say $2 ($1)"; }
}
"$CLANGDIR/bin/clang" --no-default-config -fuse-ld=lld --ld-path="$CLANGDIR/bin/ld64.lld" \
  -target x86_64-apple-macos10.12 -isysroot "$S9" -o "$t/bad" "$t/cg.c"
bad_macho "minos 10.12" "records minos and sdk '10.12"
fixture_cc -o "$t/bad" "$t/main.c"; bad_macho "no Recaulk" "_clock_gettime"
fixture_cc -Wl,-rpath,/opt/pkg/lib -o "$t/bad" "$t/cg.c"; bad_macho "an rpath into /opt/pkg" "loads /opt/pkg/lib"

S11="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch arm64)" || { echo "no 11.3 SDK could be fetched -- skipping"; exit 77; }
arm_cc() { "$CLANGDIR/bin/clang" --no-default-config -fuse-ld=lld --ld-path="$CLANGDIR/bin/ld64.lld" -isysroot "$S11" "$@"; }
# platform: the native clang22 on 10.9 and a modern Mac has no AArch64 backend; its Linux archive has
arm64_fixtures=1
"$CLANGDIR/bin/clang" -print-targets 2>/dev/null | grep -qw aarch64 || arm64_fixtures=0
[ "$arm64_fixtures" = 1 ] || [ "$(uname -s)" != Linux ] || fail "clang22's Linux archive has no AArch64 backend, and the tarball's arm64 std links with it"
if [ "$arm64_fixtures" = 1 ]; then
arm_cc --target=arm64-apple-macos11.0 -o "$t/arm" "$t/main.c"
audit_arm64 "$t/arm" arm > "$t/out" || { cat "$t/out"; fail "an arm64 fixture at minos 11.0 with the 11.3 SDK must pass the arm64 audit"; }
bad_arm() {
  if audit_arm64 "$t/bad" bad > "$t/out"; then fail "the arm64 audit passed a fixture it must refuse: $1"; fi
  grep -q "$2" "$t/out" || { cat "$t/out"; fail "the refusal must say $2 ($1)"; }
}
arm_cc --target=x86_64-apple-macos11.0 -o "$t/bad" "$t/main.c"; bad_arm "x86_64" "not thin arm64"
arm_cc --target=arm64-apple-macos12.0 -o "$t/bad" "$t/main.c"; bad_arm "minos 12.0" "records minos and sdk '12.0"
arm_cc --target=arm64-apple-macos11.0 -Wl,-rpath,/opt/homebrew/lib -o "$t/bad" "$t/main.c"; bad_arm "an rpath into /opt/homebrew" "loads /opt/homebrew/lib"
fi

elf() { "$CLANGDIR/bin/clang" --no-default-config --target=x86_64-unknown-linux-gnu -fuse-ld=lld -nostdlib -fPIC "$@"; }
printf 'int f(void) { return 1; }\n' > "$t/f.c"
printf 'int f(void);\nint _start(void) { return f(); }\n' > "$t/m.c"
E="$t/elf"; mkdir -p "$E/bin" "$E/lib" "$t/elsewhere"
elf -shared -Wl,-soname,libf.so -o "$E/lib/libf.so" "$t/f.c"
elf -shared -Wl,-soname,libc.so.6 -o "$t/elsewhere/libc.so.6" "$t/f.c"
elf -shared -Wl,-soname,libc++.so.1 -o "$t/elsewhere/libc++.so.1" "$t/f.c"
elf -o "$E/bin/tool" "$t/m.c" -L"$E/lib" -lf -L"$t/elsewhere" -l:libc.so.6 -Wl,-rpath,'$ORIGIN/../lib'
audit_linux_elf "$E" > "$t/out" || { cat "$t/out"; fail "a tool loading libc and its own lib/ through \$ORIGIN/../lib must pass the ELF audit"; }
bad_elf() {
  shift_why="$1"; shift_want="$2"; shift 2
  rm -rf "$t/bad-elf"; cp -R "$E" "$t/bad-elf"; elf -o "$t/bad-elf/bin/tool" "$t/m.c" "$@"
  if audit_linux_elf "$t/bad-elf" > "$t/out"; then fail "the ELF audit passed a fixture it must refuse: $shift_why"; fi
  grep -qF "$shift_want" "$t/out" || { cat "$t/out"; fail "the refusal must say $shift_want ($shift_why)"; }
}
bad_elf "libc++ from the build host" "needs libc++.so.1" -L"$E/lib" -lf -L"$t/elsewhere" -l:libc++.so.1 -Wl,-rpath,'$ORIGIN/../lib'
bad_elf "no RUNPATH" "needs libf.so" -L"$E/lib" -lf
bad_elf "an absolute RUNPATH" "RUNPATH names /work/lib" -L"$E/lib" -lf -Wl,-rpath,'$ORIGIN/../lib:/work/lib'
bad_elf "DT_RPATH" "DT_RPATH" -L"$E/lib" -lf -Wl,--disable-new-dtags -Wl,-rpath,'$ORIGIN/../lib'

TB="${1:-}"; PROBE="${2:-}"; named=0
[ -z "$TB" ] || named=1
if [ "$named" = 0 ]; then
  for _f in "$ROOT"/dist/rust-*-linux-x86_64.tar.gz; do [ -f "$_f" ] || continue; [ -z "$TB" ] || fail "dist/ holds more than one Linux tarball"; TB="$_f"; done
  [ -n "$TB" ] || { echo "OK linux-smoke (fixtures; no Linux tarball in dist/)"; exit 0; }
fi
[ -f "$TB" ] || fail "no Linux tarball at $TB"
[ "$(uname -s)" = Linux ] || {
  [ "$named" = 0 ] || fail "the Linux tarball runs on Linux, and this is $(uname -s)"
  echo "OK linux-smoke (fixtures; the executing half needs Linux, and this is $(uname -s))"; exit 0
}

P="$t/rust"
python3 "$SHIPYARD_SCRIPTS/product-tar.py" "$TB" "$NATIVE_SHORT" "$(_sha256 "$TB")" "$P" > /dev/null \
  || fail "shipyard's product-tar.py refuses $TB (fetch_product_tar.sh's contract: everything under opt/mavergreen/$NATIVE_SHORT, no absolute symlinks)"
for _b in rustc cargo rustdoc clippy-driver cargo-clippy rustfmt cargo-fmt; do
  [ -x "$P/bin/$_b" ] || fail "the tarball lacks bin/$_b"
done
audit_linux_elf "$P" > "$t/out" || { cat "$t/out"; fail "the tarball's ELF loads what the glibc floor does not provide"; }
for _b in rustc cargo rustdoc clippy-driver rustfmt; do
  "$P/bin/$_b" --version > "$t/out" 2>&1 || { cat "$t/out"; fail "bin/$_b --version does not run on $(getconf GNU_LIBC_VERSION 2>/dev/null)"; }
done
vv="$("$P/bin/rustc" -vV)"
printf '%s\n' "$vv" | grep -qx 'host: x86_64-unknown-linux-gnu' || fail "rustc -vV names no Linux host: $vv"
printf '%s\n' "$vv" | grep -qx "release: $RUST_VERSION" || fail "rustc -vV names no release $RUST_VERSION: $vv"
_mv="$(awk '/<key>version<\/key>/ { getline; sub(/.*<string>/, ""); sub(/<\/string>.*/, ""); print; exit }' "$P/mavergreen.plist" 2>/dev/null || :)"
case "$(basename "$TB")" in "$NATIVE_SHORT-$_mv-linux-x86_64.tar.gz") : ;;
  *) fail "the tarball's mavergreen.plist names version '$_mv', not $(basename "$TB")'s (install-products.sh reads it instead of the pkg's)" ;; esac
grep -q '<string>dev.mavergreen.rust.rust</string>' "$P/mavergreen.plist" || fail "the tarball's mavergreen.plist is not rust's"
[ -f "$P/lib/rustlib/$TARGET_TRIPLE/lib/librecaulk.a" ] || fail "the tarball lacks lib/rustlib/$TARGET_TRIPLE/lib/librecaulk.a"
sh "$HERE/target/target-core2.sh" "$P/bin/rustc" > "$t/out" 2>&1 || { cat "$t/out"; fail "the tarball's rustc targets 10.9 and core2 by default (patch 0003)"; }
grep '^PASS' "$t/out"

A="$t/app"; mkdir -p "$A/src"
printf '[package]\nname = "smoke"\nversion = "0.1.0"\nedition = "2021"\n' > "$A/Cargo.toml"
cat > "$A/src/main.rs" <<'RS'
use std::collections::HashMap;
use std::time::Instant;
fn main() {
    let start = Instant::now();
    let mut m = HashMap::new();
    m.insert("mavericks", 109);
    println!("smoke {:?} {}", m.get("mavericks"), start.elapsed().as_secs() < 60);
}
RS
CARGO_HOME="$t/cargo-home" CARGO_TARGET_DIR="$t/target" RUSTC="$P/bin/rustc" RUSTDOC="$P/bin/rustdoc" \
  CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER="$CLANGDIR/bin/clang++" SDKROOT="$S9" \
  "$P/bin/cargo" build --offline --manifest-path "$A/Cargo.toml" --target "$TARGET_TRIPLE" > "$t/out" 2>&1 \
  || { cat "$t/out"; fail "cargo build --target $TARGET_TRIPLE with clang22's clang++ and the 10.9 SDK"; }
audit_macho "$t/target/$TARGET_TRIPLE/debug/smoke" "the $TARGET_TRIPLE smoke" > "$t/out" || { cat "$t/out"; fail "the 10.9 program cargo built"; }
[ -z "$PROBE" ] || cp "$t/target/$TARGET_TRIPLE/debug/smoke" "$PROBE" || fail "could not copy the 10.9 program to $PROBE"

A64=aarch64-apple-darwin
[ -d "$P/lib/rustlib/$A64/lib" ] || fail "the tarball lacks lib/rustlib/$A64, the arm64 std"
[ ! -e "$P/lib/rustlib/$A64/lib/librecaulk.a" ] || fail "the tarball's arm64 std carries librecaulk.a, which is x86_64 for 10.9"
find "$P/lib/rustlib/$A64/lib" -type f -name '*.dylib' > "$t/arm-dylibs"
[ -s "$t/arm-dylibs" ] || fail "no $A64 dylib under the tarball's lib/rustlib -- nothing audited"
while IFS= read -r _d; do
  audit_arm64 "$_d" "${_d#"$P"/}" > "$t/out" || { cat "$t/out"; fail "the tarball's arm64 std"; }
done < "$t/arm-dylibs"
write_pinned_cc "$t/cc-arm64" "$S11" "$CLANGDIR"
CARGO_HOME="$t/cargo-home" CARGO_TARGET_DIR="$t/target" RUSTC="$P/bin/rustc" RUSTDOC="$P/bin/rustdoc" \
  CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER="$t/cc-arm64" SDKROOT="$S11" \
  "$P/bin/cargo" build --offline --manifest-path "$A/Cargo.toml" --target "$A64" > "$t/out" 2>&1 \
  || { cat "$t/out"; fail "cargo build --target $A64 with clang22 (no cfg) and the 11.3 SDK"; }
audit_arm64 "$t/target/$A64/debug/smoke" "the $A64 smoke" > "$t/out" || { cat "$t/out"; fail "the arm64 program cargo built"; }

hostcc="$(command -v cc || command -v gcc || command -v gcc-12)" || fail "no C compiler driver on PATH links the host-target hello"
printf 'fn main() { println!("hello from {}", std::env::consts::OS); }\n' > "$t/hello.rs"
"$P/bin/rustc" -C linker="$hostcc" "$t/hello.rs" -o "$t/hello" > "$t/out" 2>&1 || { cat "$t/out"; fail "rustc hello.rs for the Linux host"; }
[ "$("$t/hello")" = "hello from linux" ] || fail "the host hello printed '$("$t/hello")'"
echo "OK linux-smoke ($(basename "$TB") on $(getconf GNU_LIBC_VERSION 2>/dev/null || uname -sr))"
