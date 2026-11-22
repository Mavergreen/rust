#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
t="$(mktemp -d "${TMPDIR:-/tmp}/stage0.XXXXXX")"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; exit 1; }
F="$ROOT/build/fetch-stage0.sh"
[ -f "$F" ] || fail "build/fetch-stage0.sh missing"
[ ! -e "$ROOT/build/fetch-stage0-onbox.sh" ] || fail "build/fetch-stage0-onbox.sh is now build/fetch-stage0.sh, for every host"
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"; export TARGET_TRIPLE MACOS_MIN REPO_ROOT
. "$ROOT/build/lib-rust.sh"
command -v write_stage0_wrappers >/dev/null || fail "lib-rust.sh has no write_stage0_wrappers"
write_stage0_wrappers "$t/s0" "$t/dist"
for b in rustc cargo; do
  w="$t/s0/bin/$b"; [ -x "$w" ] || fail "$b wrapper not executable"
  grep -qx "export DYLD_INSERT_LIBRARIES=\"$t/s0/librecaulk-stage0.dylib\"" "$w" || fail "$b: injects the wrong dylib"
  grep -qx 'export DYLD_FORCE_FLAT_NAMESPACE=1' "$w" || fail "$b: flat namespace is what lets the dylib satisfy the prebuilt's missing-on-10.9 imports"
done
grep -q "exec \"$t/dist/rustc/bin/rustc\"" "$t/s0/bin/rustc" || fail "rustc wrapper execs the wrong binary"
grep -q "exec \"$t/dist/cargo/bin/cargo\"" "$t/s0/bin/cargo" || fail "cargo wrapper execs the wrong binary"
grep -q -- '-force_load,"$RECAULK_A".* -lc++abi' "$F" \
  || fail "the stage0 dylib force-loads librecaulk.a, whose C++ catch rules call 10.9's libc++abi"

RV="$(tr -d ' \t\n' < "$ROOT/UPSTREAM_VERSION")"
H=x86_64-unknown-linux-gnu; name="rust-$RV-$H"
mkdir -p "$t/stub" "$t/fx/$name/rustc/bin" "$t/fx/$name/cargo/bin" "$t/fx/$name/rustc/lib/rustlib" \
  "$t/fx/$name/rust-std-$H/lib/rustlib/$H/lib" "$t/dist-site"
printf '#!/bin/sh\nif [ "${1:-}" = -s ]; then echo Linux; else exec %s "$@"; fi\n' "$(command -v uname)" > "$t/stub/uname"
printf '#!/bin/sh\necho "fixture rustc $*"\n' > "$t/fx/$name/rustc/bin/rustc"
printf '#!/bin/sh\necho "fixture cargo $*"\n' > "$t/fx/$name/cargo/bin/cargo"
: > "$t/fx/$name/rust-std-$H/lib/rustlib/$H/lib/libstd-fixture.rlib"
chmod +x "$t/stub/uname" "$t/fx/$name/rustc/bin/rustc" "$t/fx/$name/cargo/bin/cargo"
( cd "$t/fx" && tar -cf - "$name" ) | xz -c > "$t/dist-site/$name.tar.xz"
sha="$(cd "$t/dist-site" && { shasum -a 256 "$name.tar.xz" 2>/dev/null || sha256sum "$name.tar.xz"; } | awk '{print $1}')"
printf '%s  %s\n' "$sha" "$name.tar.xz" > "$t/dist-site/$name.tar.xz.sha256"
run_linux() {
  PATH="$t/stub:$PATH" RUST_VARIANT=native MAVERICKS_WORK="$t/work" MAVERICKS_STAGE0_BASE="file://$t/dist-site" \
    sh "$F" "$t/no-clang" "$t/no-recaulk.a"
}
s0="$(run_linux)" || fail "fetch-stage0.sh on Linux must fetch and unpack $name"
[ -n "$s0" ] && [ -d "$s0" ] || fail "fetch-stage0.sh on Linux must print STAGE0DIR (got '$s0')"
for b in rustc cargo; do
  [ -x "$s0/bin/$b" ] || fail "Linux stage0 has no executable bin/$b"
  ! grep -q DYLD_ "$s0/bin/$b" || fail "Linux stage0's bin/$b sets DYLD_*: dyld is a Mac's"
  [ "$("$s0/bin/$b" -V)" = "fixture $b -V" ] || fail "Linux stage0's bin/$b must exec the unpacked $b with its arguments"
done
[ -f "$(find "$s0" -path "*/$name/rustc/lib/rustlib/$H/lib/libstd-fixture.rlib" | head -1)" ] \
  || fail "Linux stage0 must merge rust-std-$H into rustc/lib/rustlib"
rm -rf "$t/work"
printf '%064d  %s\n' 0 "$name.tar.xz" > "$t/dist-site/$name.tar.xz.sha256"
if run_linux > "$t/out" 2> "$t/err"; then fail "fetch-stage0.sh on Linux must refuse a tarball its .sha256 does not match"; else rc=$?; fi
[ "$rc" = 1 ] || fail "a .sha256 mismatch must exit 1 (got $rc)"
grep -qF "file://$t/dist-site/$name.tar.xz" "$t/err" || fail "a .sha256 mismatch must name the URL (said: $(cat "$t/err"))"
echo "OK stage0-test"
